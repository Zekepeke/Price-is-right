from fastapi import FastAPI
from pydantic import BaseModel
import anthropic, httpx, base64, os
from dotenv import load_dotenv