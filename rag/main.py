import os
from fastapi import FastAPI
from llama_index.core import VectorStoreIndex, SimpleDirectoryReader, StorageContext, Settings
from llama_index.vector_stores.chroma import ChromaVectorStore
from llama_index.embeddings.huggingface import HuggingFaceEmbedding
from llama_index.llms.ollama import Ollama
import chromadb

app = FastAPI(title="Ghost Kitchen RAG Service")

# Model configuration [cite: 169, 189, 250]
Settings.llm = Ollama(model="llama3:latest", base_url=os.getenv("OLLAMA_HOST", "http://localhost:11434"), request_timeout=360.0)
Settings.embed_model = HuggingFaceEmbedding(model_name="BAAI/bge-base-en-v1.5")

def get_index():
    # Connect to remote Chroma [cite: 113, 446]
    db_host = os.getenv("CHROMA_HOST", "localhost")
    remote_db = chromadb.HttpClient(host=db_host, port=8000)
    chroma_collection = remote_db.get_or_create_collection("ghost_kitchen_slo")
    
    vector_store = ChromaVectorStore(chroma_collection=chroma_collection)
    storage_context = StorageContext.from_defaults(vector_store=vector_store)
    
    # Load documents from the mounted volume [cite: 63, 262, 396]
    documents = SimpleDirectoryReader("./data").load_data()
    return VectorStoreIndex.from_documents(documents, storage_context=storage_context)

# Initialize global index
index = get_index()

@app.get("/diagnose")
async def diagnose(metric: str, value: float):
    query_engine = index.as_query_engine()
    prompt = f"The {metric} is {value}. What is the SLO rule and required action?"
    response = query_engine.query(prompt)
    return {"runbook_instruction": str(response)}

@app.post("/refresh")
async def refresh_index():
    """Call this after updating the slo_runbook.md file."""
    global index
    index = get_index()
    return {"status": "Index updated with latest runbook data"}
