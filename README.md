# Price is Right Glasses

Point your Meta Ray-Ban glasses at any vintage or second-hand item and instantly know if it is worth buying. Powered by Claude or Gemini Vision, with multi-source pricing across eBay, Discogs, and trading card APIs.

---

## Architecture

```
[Meta Ray-Ban Glasses]
        | Bluetooth (camera feed)
        v
[iOS App  --  SwiftUI + Meta Wearables SDK]
        | POST /scan  (base64 image + user_id)
        v
[Python Backend  --  FastAPI]
        |--- Claude/Gemini Vision --> identifies item + picks pricing source
        |
        +--- pricing router (pricing_source flag)
        |        |--- eBay Browse API      (default)
        |        |--- Discogs API          (vinyl, CDs, cassettes)
        |        |--- Scryfall + Pokemon TCG API  (trading cards)
        |
        +--- Supabase
               |-- storage: scan-images bucket  (uploaded JPEG)
               |-- table:   scans               (item + verdict)
               |-- table:   pricing_results     (price range + source)
               |-- realtime on scans table
```

The real frontend is a SwiftUI iOS app that requires a Mac with Xcode. Until then, `test_ui.html` and `test_scan.py` serve as Windows test harnesses that simulate what the iOS app will do.

---

## Project structure

```
price-is-right/
├── backend/
│   ├── main.py              # FastAPI app, /scan endpoint
│   ├── vision/
│   │   ├── claude.py        # Anthropic claude-sonnet-4-6
│   │   ├── gemini.py        # Google gemini-2.0-flash
│   │   └── prompt.py        # Shared vision prompt
│   ├── pricing/
│   │   ├── ebay.py          # eBay Browse API
│   │   ├── discogs.py       # Discogs marketplace stats
│   │   └── tcg.py           # Scryfall (MTG) + Pokémon TCG API
│   ├── test_scan.py         # CLI test script (Windows)
│   ├── .env                 # API keys (never commit)
│   ├── .env.example
│   └── requirements.txt
└── test_ui.html             # Browser test UI (Windows, no build step)
```

---

## Supabase setup

### Schema

```sql
create table public.users (
  id         uuid primary key default gen_random_uuid(),
  email      text not null,
  created_at timestamptz default now()
);

create table public.scans (
  id              uuid primary key default gen_random_uuid(),
  user_id         uuid references public.users(id),
  created_at      timestamptz default now(),
  image_url       text,
  category        text,
  brand           text,
  condition       text,
  verdict         text,
  vision_provider text,
  confidence      float
);

create table public.pricing_results (
  id           uuid primary key default gen_random_uuid(),
  scan_id      uuid references public.scans(id),
  source       text,
  price_low    float,
  price_high   float,
  price_median float,
  item_count   int
);
```

### Storage bucket

Create a public bucket named `scan-images` in the Supabase dashboard. No MIME restriction required.

### Realtime

Run once in the Supabase SQL editor:

```sql
alter publication supabase_realtime add table public.scans;
```

### Row-level security

RLS is enabled on all three tables. The backend uses the service role key which bypasses RLS. The iOS app uses the anon key with policies that allow users to read and write only their own rows.

---

## Environment variables

| Variable | Used by | Description |
|---|---|---|
| `VISION_PROVIDER` | backend | `claude` or `gemini` |
| `ANTHROPIC_API_KEY` | backend | Required when `VISION_PROVIDER=claude` |
| `GOOGLE_API_KEY` | backend | Required when `VISION_PROVIDER=gemini` |
| `EBAY_CLIENT_ID` | backend | eBay Developer app Client ID |
| `EBAY_CLIENT_SECRET` | backend | eBay Developer app Cert ID |
| `DISCOGS_TOKEN` | backend | Discogs personal access token (required for vinyl/CD lookups) |
| `POKEMON_TCG_API_KEY` | backend | Optional; raises rate limit on Pokémon TCG API |
| `SUPABASE_URL` | backend | Project URL from Supabase dashboard |
| `SUPABASE_SERVICE_KEY` | backend | Service role key (bypasses RLS) |
| `SUPABASE_ANON_KEY` | iOS app | Anon/public key |

Copy `.env.example` to `.env` and fill in your values:

```bash
cp .env.example .env
```

---

## Getting started

### 1. Start the backend

```bash
cd backend
python -m venv venv
venv\Scripts\activate
pip install -r requirements.txt
uvicorn main:app --reload
```

Server runs at `http://localhost:8000`. Open `/docs` for Swagger UI.

---

## Testing on Windows (no Mac, no iOS device required)

The iOS app is not buildable on Windows. Two test tools replicate its behavior:

### Option A — test_ui.html (browser, recommended)

Open `test_ui.html` directly in Chrome or Edge. No server, no npm, no install required.

1. Make sure the backend is running on `http://localhost:8000`
2. Open `test_ui.html` by double-clicking it or dragging it into your browser
3. Select any JPEG or PNG of a vintage item
4. Click Scan Item
5. The result card shows the verdict, category, brand, condition, confidence score, and eBay price range

This file mimics the iOS app UI and is purely for Windows development.

### Option B — test_scan.py (terminal)

```bash
cd backend
python test_scan.py path\to\image.jpg
```

With an explicit user ID:

```bash
python test_scan.py path\to\image.jpg your-user-uuid-here
```

Prints the full JSON response. Exits with a clear error message if the backend is not running.

---

## API reference

### `POST /scan`

**Request body:**
```json
{
  "image_base64": "<base64-encoded JPEG>",
  "user_id": "<uuid or null>"
}
```

**Response:**
```json
{
  "scan_id": "uuid",
  "item": {
    "category": "vinyl record",
    "brand": "The Beatles",
    "condition": "good",
    "pricing_source": "discogs",
    "search_query": "Beatles Abbey Road vinyl",
    "confidence": 0.92
  },
  "pricing": {
    "low": 8.99,
    "high": 45.00,
    "median": 18.50,
    "count": 10
  },
  "verdict": "Fair price",
  "image_url": "https://your-project.supabase.co/storage/v1/object/public/scan-images/uuid.jpg"
}
```

Possible verdict values: `Great deal`, `Fair price`, `Overpriced`, `No pricing data`.

---

## Vision providers

| Provider | Model | Notes |
|---|---|---|
| Claude (Anthropic) | `claude-sonnet-4-6` | Strong brand recognition and condition grading |
| Gemini (Google) | `gemini-2.0-flash` | Fast and cost-effective for high-volume scanning |

Both return the same response shape. Switch by changing `VISION_PROVIDER` in `.env`.

---

## Pricing sources

The vision model tags each item with a `pricing_source` and the router dispatches to the matching API. All sources return the same `{low, high, median, count}` shape.

| Source | Used for | Auth | Notes |
|---|---|---|---|
| eBay Browse | General thrift items (clothing, electronics, housewares, toys) | OAuth2 client credentials | Returns *live* listings — asking prices, not sold. Sold-data would require eBay Marketplace Insights API (gated approval). |
| Discogs | Vinyl, CDs, cassettes, music media | Personal access token | Uses `/marketplace/stats` — currently returns only `lowest_price`, so low/high/median are equal in v1. |
| Scryfall | Magic: The Gathering cards | None | Free public API; returns USD + USD foil prices. |
| Pokémon TCG API | Pokémon cards | Optional API key | Embeds TCGPlayer `low/mid/high` prices. Only reads the `normal` price variant — holofoil-only cards will return 0. |

---

## iOS app (requires Mac)

The real frontend is a SwiftUI app that uses the Meta Wearables SDK to receive camera frames from the glasses over Bluetooth. It is the only part of this project that requires a Mac with Xcode 14+ and a physical iOS device.

When the iOS app captures a frame it does one thing: POST to `/scan` with the base64-encoded image and the authenticated user's UUID. Everything else runs in the Python backend.

You can build and validate the entire backend pipeline on Windows using the test tools above, then connect the iOS app later without changing any backend code.

---

## Roadmap

- [x] Claude Vision item identification
- [x] Gemini Vision item identification
- [x] eBay pricing via Browse API
- [x] Discogs pricing for vinyl and CDs
- [x] Scryfall + Pokémon TCG pricing for trading cards
- [x] Supabase persistence and image storage
- [x] Windows test harness (test_ui.html + test_scan.py)
- [ ] SwiftUI iOS app with Meta Wearables SDK
- [ ] Text-to-speech verdict read aloud through glasses speaker
- [ ] Improve Discogs price distribution (paginate marketplace/search)
- [ ] Handle holofoil-only Pokémon cards in tcg.py
- [ ] eBay Marketplace Insights API for sold-data (post-hackathon)
- [ ] Poshmark / Mercari pricing sources
- [ ] Price history trend (not just current listings)
