import sys
import base64
import json
import httpx

# ---------------------------------------------------------------
# test_scan.py
#
# Prerequisites:
#   1. Start the backend first:
#        uvicorn main:app --reload
#   2. Make sure your .env has GOOGLE_API_KEY, EBAY_CLIENT_ID,
#      and EBAY_CLIENT_SECRET set.
#
# Usage:
#   Basic (uses a default dummy user ID):
#        python test_scan.py path\to\image.jpg
#
#   With an explicit user ID:
#        python test_scan.py path\to\image.jpg your-user-uuid-here
#
# Prints the full JSON response from the backend.
# Exits with a clear error message if the backend is not running.
# ---------------------------------------------------------------

BACKEND_URL = "http://localhost:8000/scan"
TEST_USER_ID = "00000000-0000-0000-0000-000000000000"


def main():
    if len(sys.argv) < 2:
        print("Usage: python test_main.py path/to/image.jpg [user_id]")
        sys.exit(1)

    image_path = sys.argv[1]
    user_id = sys.argv[2] if len(sys.argv) > 2 else TEST_USER_ID

    with open(image_path, "rb") as f:
        image_b64 = base64.b64encode(f.read()).decode()

    print(f"Sending {image_path} to {BACKEND_URL} ...")

    try:
        response = httpx.post(
            BACKEND_URL,
            json={"image_base64": image_b64, "user_id": user_id},
            timeout=60.0,
        )
        response.raise_for_status()
    except httpx.HTTPStatusError as e:
        print(f"HTTP error {e.response.status_code}: {e.response.text}")
        sys.exit(1)
    except httpx.RequestError as e:
        print(f"Connection error: {e}")
        print("Make sure the backend is running: uvicorn main:app --reload")
        sys.exit(1)

    print(json.dumps(response.json(), indent=2))


if __name__ == "__main__":
    main()