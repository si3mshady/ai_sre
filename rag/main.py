import os
import time
from fastapi import FastAPI
from llama_index.core import VectorStoreIndex, SimpleDirectoryReader, StorageContext, Settings
from llama_index.vector_stores.chroma import ChromaVectorStore
from llama_index.embeddings.huggingface import HuggingFaceEmbedding
from llama_index.llms.ollama import Ollama
import chromadb

app = FastAPI(title="Ghost Kitchen Token Factory")

# 1. Model & Embedding Config
# Using llama3.1 for higher-quality reasoning
Settings.llm = Ollama(
        model="llama3:latest", 
    base_url=os.getenv("OLLAMA_HOST", "http://localhost:11434"), 
    request_timeout=360.0
)
Settings.embed_model = HuggingFaceEmbedding(model_name="BAAI/bge-base-en-v1.5")

def get_index():
    db_host = os.getenv("CHROMA_HOST", "localhost")
    remote_db = chromadb.HttpClient(host=db_host, port=8000)
    chroma_collection = remote_db.get_or_create_collection("ghost_kitchen_slo")
    vector_store = ChromaVectorStore(chroma_collection=chroma_collection)
    storage_context = StorageContext.from_defaults(vector_store=vector_store)
    documents = SimpleDirectoryReader("./data").load_data()
    return VectorStoreIndex.from_documents(documents, storage_context=storage_context)

# Initial index load
index = get_index()

@app.get("/diagnose")
async def diagnose(metric: str, value: float):
    start_time = time.perf_counter()
    query_engine = index.as_query_engine()
    
    prompt = f"The {metric} is {value}. What is the exact SLO rule and required action?"
    response = response = query_engine.query(prompt)
    
    end_time = time.perf_counter()
    latency_ms = (end_time - start_time) * 1000

    # 2. Extract Token Factory Metadata
    # LlamaIndex stores the raw Ollama response in the 'raw' key of metadata
    raw_meta = response.metadata.get(list(response.metadata.keys())[0], {})
    
    # These fields come directly from the Ollama API response
    prompt_tokens = raw_meta.get("prompt_eval_count", 0)
    completion_tokens = raw_meta.get("eval_count", 0)
    total_tokens = prompt_tokens + completion_tokens
    
    # Calculate Efficiency (Tokens Per Second)
    tps = completion_tokens / (latency_ms / 1000) if latency_ms > 0 else 0

    return {
        "runbook_instruction": str(response),
        "factory_metrics": {
            "input_tokens": prompt_tokens,
            "output_tokens": completion_tokens,
            "total_tokens": total_tokens,
            "latency_ms": round(latency_ms, 2),
            "tokens_per_second": round(tps, 2),
            "inference_cost_est": f"${(total_tokens * 0.00002):.6f}" 
        }
    }

@app.post("/refresh")
async def refresh_index():
    global index
    index = get_index()
    return {"status": "Index updated"}
