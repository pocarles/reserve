# Reserve 1.6.6

Cache savings now stay visible when only part of your activity can be priced.
Reserve labels the estimate as partial and shows the percentage of cached input
it covers. When no cache reads can be priced, it shows "Price unavailable".
These figures estimate API pricing, not savings on your subscription bill.

OpenAI history now searches farther back for a complete model context in long
sessions. Reserve no longer assumes a GPT-5.6 rate when the model is missing.
Existing OpenAI history is checked again in the background, with saved token
totals kept visible during the update.
