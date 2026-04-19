def build_speech(item: dict, pricing: dict, verdict: str) -> str:
    """Build a simple spoken sentence from scan results.
    Used as fallback if the LLM summary fails."""
    brand = item.get("brand", "unknown brand")
    category = item.get("category", "item")
    condition = item.get("condition", "")

    parts = []
    if condition:
        parts.append(f"This looks like a {brand} {category} in {condition} condition.")
    else:
        parts.append(f"This looks like a {brand} {category}.")

    if pricing and pricing.get("median"):
        low = pricing["low"]
        high = pricing["high"]
        median = pricing["median"]
        if low == high:
            parts.append(f"Similar items are listed around ${median:.0f}.")
        else:
            parts.append(
                f"Similar items range from ${low:.0f} to ${high:.0f}, with a median of ${median:.0f}."
            )
    else:
        parts.append("I couldn't find comparable prices online.")

    parts.append(f"Verdict: {verdict}.")
    return " ".join(parts)
