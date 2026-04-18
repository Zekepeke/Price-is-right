# Quick test in Python, make sure to run main.py first
import base64, httpx

with open("test_item.jpg", "rb") as f:
    img = base64.b64encode(f.read()).decode()

r = httpx.post("http://localhost:8000/scan", json={"image_base64": img})
print(r.json())