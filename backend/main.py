from fastapi import FastAPI
from pydantic import BaseModel
import anthropic, httpx, base64, os
from dotenv import load_dotenv

load_dotenv()
app = FastAPI()
claude = anthropic.Anthropic(api_key=os.getenv("ANTHROPIC_API_KEY"))
