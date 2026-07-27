(() => {
  "use strict";
  const QUEUE_KEY="nk-hub-sync-queue-v1";
  const config=window.NK_SUPABASE||{};
  const configured=Boolean(config.url&&config.publishableKey&&window.supabase);
  const client=configured?window.supabase.createClient(config.url,config.publishableKey):null;
  let user=null,syncing=false;

  const readQueue=()=>{
    try{return JSON.parse(localStorage.getItem(QUEUE_KEY)||"[]")}catch{return[]}
  };
  const writeQueue=queue=>localStorage.setItem(QUEUE_KEY,JSON.stringify(queue));
  const notify=detail=>window.dispatchEvent(new CustomEvent("nk-sync",{detail}));
  const enqueue=(type,payload)=>{
    const queue=readQueue();
    queue.push({id:crypto.randomUUID?crypto.randomUUID():String(Date.now())+Math.random(),type,payload,createdAt:new Date().toISOString()});
    writeQueue(queue);notify({status:"queued",pending:queue.length});
    if(user&&navigator.onLine)setTimeout(sync,500);
  };
  async function collectionId(code){
    const {data,error}=await client.from("collections").select("id").eq("collection_code",code).maybeSingle();
    if(error)throw error;
    return data&&data.id;
  }
  async function execute(operation){
    if(operation.type==="collection"){
      const {error}=await client.from("collections").upsert(operation.payload,{onConflict:"collection_code",ignoreDuplicates:true});
      if(error)throw error;return;
    }
    const id=await collectionId(operation.payload.collection_code);
    if(!id)throw new Error("Coleta ainda não sincronizada.");
    if(operation.type==="scan"){
      const payload={...operation.payload,collection_id:id};delete payload.collection_code;
      const {error}=await client.from("scans").insert(payload);
      if(error)throw error;
      return;
    }
    if(operation.type==="finish"){
      const {error}=await client.from("collections").update({status:"finished",finished_at:operation.payload.finished_at}).eq("id",id);
      if(error)throw error;
    }
  }
  async function sync(){
    if(!configured||!user||!navigator.onLine||syncing)return;
    syncing=true;
    const queue=readQueue(),remaining=[];
    for(const operation of queue){
      try{await execute(operation)}
      catch(error){
        if(error&&error.code==="23505")notify({status:"duplicate",code:operation.payload.code_value});
        else remaining.push(operation);
      }
    }
    writeQueue(remaining);syncing=false;
    notify({status:remaining.length?"queued":"synced",pending:remaining.length});
  }
  async function run(type,payload){
    if(!configured)return{ok:false,configured:false};
    const operation={type,payload};
    if(!user||!navigator.onLine){enqueue(type,payload);return{ok:true,queued:true}}
    try{await execute(operation);return{ok:true,queued:false}}
    catch(error){
      if(error&&error.code==="23505")return{ok:false,duplicate:true,error};
      enqueue(type,payload);return{ok:true,queued:true,error};
    }
  }
  async function init(){
    if(!configured)return{configured:false,user:null};
    const {data}=await client.auth.getSession();user=data.session&&data.session.user;
    if(user){
      const active=await isActiveUser();
      if(!active){await client.auth.signOut();user=null;return{configured:true,user:null,inactive:true}}
    }
    client.auth.onAuthStateChange((_event,session)=>{user=session&&session.user;if(user)sync()});
    window.addEventListener("online",sync);
    if(user)sync();
    return{configured:true,user};
  }
  async function isActiveUser(){
    if(!user)return false;
    const {data,error}=await client.from("profiles").select("id,active,role").eq("id",user.id).maybeSingle();
    return !error&&data&&data.active&&data.role;
  }
  async function signIn(email,password){
    const {data,error}=await client.auth.signInWithPassword({email,password});
    if(!error){
      user=data.user;
      const active=await isActiveUser();
      if(!active){
        await client.auth.signOut();user=null;
        return{user:null,error:{message:"Usuário sem liberação ativa."}};
      }
      sync()
    }
    return{user:data&&data.user,error};
  }
  async function signOut(){if(client)await client.auth.signOut();user=null}
  async function createCollection(collection){
    if(!user)return{ok:false,auth:true};
    return run("collection",{
      collection_code:collection.id,carrier:collection.carrier,plate:collection.plate,
      driver:collection.driver,helper:collection.helper||null,operator_id:user.id,
      operator_email:user.email||"",started_at:collection.startedAt,status:"open"
    });
  }
  async function addScan(collection,record){
    if(!user)return{ok:false,auth:true};
    return run("scan",{
      collection_code:collection.id,code_value:record.value,code_type:record.type,
      source:record.source,scanned_by:user.id,scanned_by_email:user.email||"",
      scanned_at:new Date().toISOString()
    });
  }
  async function finishCollection(collection){
    return run("finish",{collection_code:collection.id,finished_at:collection.finishedAt||new Date().toISOString()});
  }
  window.NKData={configured,client,init,signIn,signOut,createCollection,addScan,finishCollection,sync,getUser:()=>user,getPending:()=>readQueue().length};
})();
