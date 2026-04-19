import os


def generate_summary(item: dict, pricing: dict, verdict: str) -> str:
    try:
        provider = os.getenv("VISION_PROVIDER", "claude").lower()
        if provider == "gemini":
            return _gemini_summary(item, pricing, verdict)
        return _claude_summary(item, pricing, verdict)
    except Exception as e:
        print(f"[SUMMARY] ERROR: {type(e).__name__}: {e}")
        return _fallback_summary(item, pricing, verdict)


def _build_prompt(item: dict, pricing: dict, verdict: str) -> str:
    source = pricing.get("actual_source", pricing.get("requested_source", "eBay"))
    source_label = {"ebay": "eBay", "discogs": "Discogs", "tcg": "TCGPlayer"}.get(source, source)
    fallback_note = ""
    if pricing.get("used_fallback"):
        original = pricing.get("requested_source", "")
        original_label = {"ebay": "eBay", "discogs": "Discogs", "tcg": "TCGPlayer"}.get(original, original)
        fallback_note = f" (no results on {original_label}, fell back to eBay)"

    return f"""You are summarizing a secondhand item scan result. Write exactly 2-3 sentences in a friendly, conversational tone.

Item data:
- Category: {item.get("category", "unknown")}
- Brand: {item.get("brand", "unknown")}
- Condition: {item.get("condition", "unknown")}
- Search query used: {item.get("search_query", "")}

Pricing data:
- Source: {source_label}{fallback_note}
- Listings found: {pricing.get("count", 0)}
- Price range: ${pricing.get("low", 0):.2f} – ${pricing.get("high", 0):.2f}
- Median price: ${pricing.get("median", 0):.2f}
- Verdict: {verdict}

Rules:
- Mention what the item is and its condition
- Mention the price source and range (or say no data was found if count is 0)
- If a fallback happened, naturally mention it (e.g. "I couldn't find it on Discogs so I checked eBay instead")
- Based on your own knowledge of this item, state what YOU think a fair price is (e.g. "I'd expect this to go for around $X")
- End with the verdict
- Be concise — 2-3 sentences max
- Do NOT use markdown, bullet points, or headers — plain text only"""


def _claude_summary(item: dict, pricing: dict, verdict: str) -> str:
    import anthropic
    client = anthropic.Anthropic(api_key=os.environ["ANTHROPIC_API_KEY"])
    msg = client.messages.create(
        model="claude-sonnet-4-6",
        max_tokens=200,
        messages=[{"role": "user", "content": _build_prompt(item, pricing, verdict)}],
    )
    return msg.content[0].text.strip()


def _gemini_summary(item: dict, pricing: dict, verdict: str) -> str:
    from google import genai
    client = genai.Client(api_key=os.environ["GOOGLE_API_KEY"])
    response = client.models.generate_content(
        model="gemini-2.5-flash",
        contents=_build_prompt(item, pricing, verdict),
    )
    return response.text.strip()


def _fallback_summary(item: dict, pricing: dict, verdict: str) -> str:
    brand = item.get("brand") or ""
    category = item.get("category") or "item"
    condition = item.get("condition") or "unknown"
    if pricing.get("count", 0) > 0:
        return (
            f"{brand} {category} in {condition} condition. "
            f"Prices range from ${pricing['low']:.2f} to ${pricing['high']:.2f} "
            f"(median ${pricing['median']:.2f}). Verdict: {verdict}."
        ).strip()
    return f"{brand} {category} in {condition} condition. No pricing data found. Verdict: {verdict}.".strip()
