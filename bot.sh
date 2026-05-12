#!/bin/bash
# ================================================================
#   SMARTPAL TELEGRAM BOT — v3.0 Professional
#   Engineer  : Built clean from scratch
#   Owner     : Sanusi Abdbasit (@Bazman)
#   AI        : Groq API (llama-3.1-8b-instant) — Free
#
#   FEATURES:
#     Greets user by name (asks on first use)
#     Natural AI chat — like ChatGPT
#     Explain any topic (definition + simple + example)
#     Re-explain if confused
#     MCQ Quiz on any topic (user picks 1-20 questions)
#     Score + full explanation after every answer
#     PDF Study — upload PDF → get MCQ, theory, summary, explanation
#     Financial advisor (income, budget, spending alerts)
#     Expense tracker
#     Motivational quotes (/quote works)
#     Trainable (/teach /correct)
#     Usage limit (20 free AI actions/day, 3 PDFs/day)
#     Admin tools (boost, reset, broadcast)
#     Telegram command menu (sidebar)
#     Security hardened (input sanitization)
# ================================================================

# NOTE: errexit/nounset/pipefail removed — they cause silent crashes
# in a bot loop where some commands legitimately return non-zero.

# ──────────────────────────────────────────────────────────────
# CONFIGURATION — supports env vars for Railway deployment
# ──────────────────────────────────────────────────────────────
BOT_TOKEN="${BOT_TOKEN:-}"
GROQ_API_KEY="${GROQ_API_KEY:-}"
ADMIN_CHAT_ID="${ADMIN_CHAT_ID:-8382934002}"
ADMIN_USERNAME="@Bazman"

FREE_LIMIT=20
BOOSTED_LIMIT=100
PDF_FREE_LIMIT=3        # PDFs per day for free users
PDF_BOOSTED_LIMIT=10    # PDFs per day for boosted users
PDF_FREE_PAGES=50       # Max pages for free users
PDF_BOOSTED_PAGES=100   # Max pages for boosted users

GROQ_URL="https://api.groq.com/openai/v1/chat/completions"
GROQ_MODEL="llama-3.1-8b-instant"
TG_URL="https://api.telegram.org/bot${BOT_TOKEN}"

# ──────────────────────────────────────────────────────────────
# PATHS
# ──────────────────────────────────────────────────────────────
BOT_DIR="${BOT_DIR:-$HOME/telegram_bot}"
USERS_DIR="$BOT_DIR/users"
QUOTES_FILE="$BOT_DIR/quotes.txt"
EXPENSES_FILE="$BOT_DIR/expenses.csv"
KNOWLEDGE_FILE="$BOT_DIR/knowledge.txt"
OFFSET_FILE="$BOT_DIR/.offset"
QUIZ_FILE="$BOT_DIR/.quiz_pending"
LOG_FILE="$BOT_DIR/bot.log"

mkdir -p "$USERS_DIR"
touch "$KNOWLEDGE_FILE" "$LOG_FILE" 2>/dev/null
# Expenses are now per-user — files created on first use in log_expense()

# Quotes
[[ ! -f "$QUOTES_FILE" ]] && cat > "$QUOTES_FILE" << 'ENDQUOTES'
The secret of getting ahead is getting started.
Push yourself because no one else is going to do it for you.
Great things never come from comfort zones.
Dream it. Wish it. Do it.
Success does not just find you. You have to go out and get it.
The harder you work the luckier you get.
Do not stop when you are tired. Stop when you are done.
Believe you can and you are halfway there.
It always seems impossible until it is done.
Little progress each day adds up to big results.
Stay focused and never give up.
One day or day one. You decide.
Stop waiting for motivation. Build discipline.
Your current situation is not your final destination.
Scars are proof that you fought and survived.
If you do not like your destiny do not accept it. Instead have the courage to change it. — Naruto
Power comes in response to a need not a desire. — Goku
A dropout will beat a genius through hard work. — Rock Lee
Go beyond. Plus Ultra. — All Might
Believe in the you who believes in yourself. — Kamina
Hard work is worthless for those who do not believe in themselves. — Naruto
Being weak is nothing to be ashamed of. Staying weak is. — Black Clover
Even if I have to drag my feet I will move forward. — Natsu Dragneel
Failure is not the end. It is the beginning of a new attempt. — Erza Scarlet
Giving up is what kills people. When people reject giving up they can change the world. — Saitama
Do not pray for an easy life. Pray for the strength to endure a difficult one.
The strongest people are not those who never fall. They are those who get back up every time.
Wake up with determination. Go to bed with satisfaction.
Your future is something you create with your own two hands. — Edward Elric
The only way to truly escape the mundane is to constantly be evolving.
ENDQUOTES

# ──────────────────────────────────────────────────────────────
# SECURITY — sanitize all user input
# ──────────────────────────────────────────────────────────────
sanitize() {
    # Remove dangerous characters, limit to 500 chars
    echo "$1" | tr -d '`$\\' | cut -c1-500
}

# ──────────────────────────────────────────────────────────────
# LOGGING
# ──────────────────────────────────────────────────────────────
log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" >> "$LOG_FILE"; }

# ──────────────────────────────────────────────────────────────
# TELEGRAM
# ──────────────────────────────────────────────────────────────
send_msg() {
    local cid="$1" txt="$2"
    curl -s -X POST "${TG_URL}/sendMessage" \
        -d chat_id="$cid" \
        --data-urlencode text="$txt" \
        -d parse_mode="Markdown" > /dev/null 2>&1 || true
}

# Send message with persistent bottom keyboard (like BONKbot style)
send_keyboard() {
    local cid="$1" txt="$2"
    local keyboard='{"keyboard":[[{"text":"🧠 Quiz"},{"text":"📚 Explain"},{"text":"☀️ Quote"}],[{"text":"💰 Finance"},{"text":"📊 Summary"},{"text":"📋 Budget"}],[{"text":"💸 Log Expense"},{"text":"📈 Status"},{"text":"❓ Help"}]],"resize_keyboard":true,"persistent":true}'
    RAW_TXT="$txt" RAW_KB="$keyboard" RAW_CID="$cid" RAW_URL="$TG_URL" python3 << 'PYEOF'
import os, urllib.request, json
cid = os.environ["RAW_CID"]
txt = os.environ["RAW_TXT"]
kb  = os.environ["RAW_KB"]
url = os.environ["RAW_URL"] + "/sendMessage"
data = json.dumps({"chat_id": cid, "text": txt, "parse_mode": "Markdown", "reply_markup": kb}).encode()
req = urllib.request.Request(url, data=data, headers={"Content-Type": "application/json"})
try: urllib.request.urlopen(req, timeout=10)
except: pass
PYEOF
}

# Send message with inline keyboard buttons
send_buttons() {
    local cid="$1" txt="$2" btns="$3"
    local keyboard
    keyboard=$(python3 << PYEOF
import json, os
rows_raw = ${btns}
rows = []
for row in rows_raw:
    r = []
    for label, cmd in zip(row[::2], row[1::2]):
        r.append({"text": label, "callback_data": cmd})
    rows.append(r)
print(json.dumps({"inline_keyboard": rows}))
PYEOF
    )
    RAW_TXT="$txt" RAW_KB="$keyboard" RAW_CID="$cid" RAW_URL="$TG_URL" python3 << 'PYEOF'
import os, urllib.request, urllib.parse, json
cid = os.environ["RAW_CID"]
txt = os.environ["RAW_TXT"]
kb  = os.environ["RAW_KB"]
url = os.environ["RAW_URL"] + "/sendMessage"
data = json.dumps({"chat_id": cid, "text": txt, "parse_mode": "Markdown", "reply_markup": kb}).encode()
req = urllib.request.Request(url, data=data, headers={"Content-Type": "application/json"})
try: urllib.request.urlopen(req, timeout=10)
except: pass
PYEOF
}

get_offset() { [[ -f "$OFFSET_FILE" ]] && cat "$OFFSET_FILE" || echo "0"; }
save_offset() { echo "$1" > "$OFFSET_FILE"; }

# ──────────────────────────────────────────────────────────────
# USER DATA — simple key/value per user
# ──────────────────────────────────────────────────────────────
uset() { printf "%s" "$3" > "$USERS_DIR/${1}_${2}"; }
uget() { local f="$USERS_DIR/${1}_${2}"; [[ -f "$f" ]] && cat "$f" || echo ""; }
uflag_set()   { touch "$USERS_DIR/${1}_flag_${2}"; }
uflag_clear() { rm -f "$USERS_DIR/${1}_flag_${2}"; }
uflag_check() { [[ -f "$USERS_DIR/${1}_flag_${2}" ]] && echo "yes" || echo "no"; }

# ──────────────────────────────────────────────────────────────
# USAGE LIMITS
# ──────────────────────────────────────────────────────────────
get_limit() {
    local cid="$1"
    grep -qx "$cid" "$BOT_DIR/boosted.txt" 2>/dev/null && \
        echo "$BOOSTED_LIMIT" || echo "$FREE_LIMIT"
}

get_usage() {
    local cid="$1" f="$USERS_DIR/${1}_usage"
    [[ ! -f "$f" ]] && echo "0" && return
    local d c; d=$(cut -d'|' -f1 "$f"); c=$(cut -d'|' -f2 "$f")
    [[ "$d" == "$(date '+%Y-%m-%d')" ]] && echo "$c" || echo "0"
}

inc_usage() {
    local cid="$1" cur
    cur=$(get_usage "$cid")
    echo "$(date '+%Y-%m-%d')|$(( cur + 1 ))" > "$USERS_DIR/${cid}_usage"
}

can_ai() {
    local cid="$1"
    [[ $(get_usage "$cid") -lt $(get_limit "$cid") ]] && echo "yes" || echo "no"
}

usage_note() {
    local cid="$1" used lim rem
    used=$(get_usage "$cid"); lim=$(get_limit "$cid"); rem=$(( lim - used ))
    echo "_[${rem}/${lim} free AI actions left today]_"
}

limit_msg() {
    local cid="$1" lim
    lim=$(get_limit "$cid")
    send_msg "$cid" "⛔ *Daily limit reached!*

You have used all *${lim}* free AI actions today.
Limit resets at *midnight* 🌙

Contact ${ADMIN_USERNAME} for more access."
}

# ──────────────────────────────────────────────────────────────
# GROQ AI — single clean function
# ──────────────────────────────────────────────────────────────
ask_ai() {
    local system_msg="$1" user_msg="$2"

    printf "%s" "$system_msg" > "$BOT_DIR/.sys.tmp"
    printf "%s" "$user_msg"   > "$BOT_DIR/.usr.tmp"

    local raw
    raw=$(SYS_FILE="$BOT_DIR/.sys.tmp" USR_FILE="$BOT_DIR/.usr.tmp" \
          GEMINI_KEY="$GEMINI_API_KEY" GEMINI_ENDPOINT="$GEMINI_URL" python3 << 'PYEOF'
import os, json, urllib.request, re

sys_msg  = open(os.environ["SYS_FILE"]).read().strip()
usr_msg  = open(os.environ["USR_FILE"]).read().strip()
key      = os.environ["GEMINI_KEY"]
endpoint = os.environ["GEMINI_ENDPOINT"]

# Gemini payload — system instruction + user message
payload = {
    "system_instruction": {
        "parts": [{"text": sys_msg}]
    },
    "contents": [
        {"role": "user", "parts": [{"text": usr_msg}]}
    ],
    "generationConfig": {
        "temperature": 0.75,
        "maxOutputTokens": 1000
    }
}

url = f"{endpoint}?key={key}"
req = urllib.request.Request(
    url,
    data=json.dumps(payload).encode(),
    headers={"Content-Type": "application/json"}
)
try:
    with urllib.request.urlopen(req, timeout=30) as r:
        d = json.loads(r.read())
        t = d["candidates"][0]["content"]["parts"][0]["text"]
        # Clean markdown symbols
        t = re.sub(r"\*\*", "", t)
        t = re.sub(r"^#+\s*", "", t, flags=re.M)
        t = re.sub(r"^[-•]\s*", "", t, flags=re.M)
        print(t.strip())
except Exception as e:
    print("")
PYEOF
    )
    echo "$raw"
}

# ──────────────────────────────────────────────────────────────
# PARSE TELEGRAM UPDATES — using python3 reliably
# ──────────────────────────────────────────────────────────────
parse_update() {
    local json="$1" idx="$2" field="$3"
    # FIX: Pass args via env vars — sys.argv does not work with heredoc
    PU_JSON="$json" PU_IDX="$idx" PU_FIELD="$field" python3 << 'PYEOF'
import os, json as j
try:
    d = j.loads(os.environ["PU_JSON"])
    r = d.get("result", [])
    i = int(os.environ["PU_IDX"])
    f = os.environ["PU_FIELD"]
    if i >= len(r): print(""); exit()
    u = r[i]
    if   f == "uid":  print(u.get("update_id", ""))
    elif f == "cid":  print(u.get("message",{}).get("chat",{}).get("id",""))
    elif f == "text": print(u.get("message",{}).get("text",""))
    else: print("")
except: print("")
PYEOF
}

# ──────────────────────────────────────────────────────────────
# REGISTER TELEGRAM COMMAND MENU
# ──────────────────────────────────────────────────────────────
register_commands() {
    curl -s -X POST "${TG_URL}/setMyCommands" \
    -H "Content-Type: application/json" \
    -d '{
      "commands": [
        {"command":"start",     "description":"Start SmartPal"},
        {"command":"help",      "description":"See all commands"},
        {"command":"quiz",      "description":"MCQ quiz on any topic"},
        {"command":"explain",   "description":"Explain any topic simply"},
        {"command":"quote",     "description":"Get a motivational quote"},
        {"command":"spent",     "description":"Log an expense"},
        {"command":"summary",   "description":"Financial summary report"},
        {"command":"budget",    "description":"See your budget plan"},
        {"command":"setincome", "description":"Set your monthly income"},
        {"command":"status",    "description":"Your account and usage"},
        {"command":"teach",     "description":"Teach the bot something new"},
        {"command":"correct",   "description":"Correct a wrong answer"},
        {"command":"hint",      "description":"Get a quiz hint"},
        {"command":"skip",      "description":"Skip current quiz question"},
        {"command":"newchat",   "description":"Clear conversation history"}
      ]
    }' > /dev/null 2>&1 || true
}

# ──────────────────────────────────────────────────────────────
# QUOTES
# ──────────────────────────────────────────────────────────────
send_quote() {
    local cid="$1" total rnd quote
    total=$(wc -l < "$QUOTES_FILE")
    rnd=$(( (RANDOM % total) + 1 ))
    quote=$(sed -n "${rnd}p" "$QUOTES_FILE")
    send_msg "$cid" "☀️ *SmartPal Quote:*

_\"${quote}\"_

You have got this! 💪"
}

# ──────────────────────────────────────────────────────────────
# AI CHAT — natural conversation with memory
# ──────────────────────────────────────────────────────────────
ai_chat() {
    local cid="$1" question="$2"
    [[ "$(can_ai "$cid")" == "no" ]] && limit_msg "$cid" && return

    send_msg "$cid" "🤔 _Thinking..._"

    local name learned name_ctx extra
    name=$(uget "$cid" "name")
    learned=$(tail -10 "$KNOWLEDGE_FILE" 2>/dev/null | sed 's/\[.*\] //' || echo "")
    [[ -n "$name" ]]    && name_ctx="The user's name is ${name}. Use their name naturally sometimes but not every message." || name_ctx=""
    [[ -n "$learned" ]] && extra="Things users have taught you (use if relevant): ${learned}" || extra=""

    # Check if web search needed
    local web_ctx="" lower_q="${question,,}"
    if [[ "$lower_q" == *"today"* || "$lower_q" == *"current"* || "$lower_q" == *"latest"* ||           "$lower_q" == *"news"* || "$lower_q" == *"price of"* || "$lower_q" == *"exchange rate"* ||           "$lower_q" == *"dollar"* || "$lower_q" == *"naira rate"* || "$lower_q" == *"who won"* ]]; then
        web_ctx=$(web_search_context "$question")
        [[ "$web_ctx" == "NO_RESULTS" ]] && web_ctx=""
    fi

    # Load persistent memory (survives restarts)
    local memory
    memory=$(load_memory "$cid")

    local web_note=""
    [[ -n "$web_ctx" ]] && web_note="

[Current web info: ${web_ctx}]"

    local sys="You are SmartPal — a brilliant, warm, and thoughtful AI assistant made for Nigerians. Your personality is like Claude from Anthropic: genuinely curious, deeply helpful, honest, and natural in conversation. You think carefully and give real answers.

How you talk:
- Like a very smart, warm friend — never robotic or stiff
- Natural flowing sentences, not bullet points unless the topic calls for it
- Honest when you are not sure about something
- Use Nigerian context and examples naturally where it fits
- Be concise for simple questions, go deep when needed
- Show genuine interest — ask a follow-up question sometimes if it would help
- Never start with Certainly, Of course, Sure, Great question, or Absolutely
- No markdown symbols like ** or ## — plain text only
- Use Naira symbol for money
${name_ctx}
${extra}${web_note}"

    # Build messages with memory for true conversation context
    local full_q="$question"
    [[ -n "$web_ctx" ]] && full_q="${question}

[Web search results: ${web_ctx}]"

    local answer
    answer=$(MEMORY="$memory" SYS_MSG="$sys" USER_MSG="$full_q" \
             GEMINI_KEY="$GEMINI_API_KEY" GEMINI_ENDPOINT="$GEMINI_URL" python3 << 'PYEOF'
import os, json, urllib.request, re

memory_raw = os.environ.get("MEMORY", "[]")
sys_msg    = os.environ["SYS_MSG"]
user_msg   = os.environ["USER_MSG"]
key        = os.environ["GEMINI_KEY"]
endpoint   = os.environ["GEMINI_ENDPOINT"]

try:
    history = json.loads(memory_raw)
except:
    history = []

# Build Gemini contents array from history
contents = []
for msg in history[-16:]:
    role = "user" if msg["role"] == "user" else "model"
    contents.append({"role": role, "parts": [{"text": msg["content"]}]})
contents.append({"role": "user", "parts": [{"text": user_msg}]})

payload = {
    "system_instruction": {"parts": [{"text": sys_msg}]},
    "contents": contents,
    "generationConfig": {"temperature": 0.75, "maxOutputTokens": 1000}
}

url = f"{endpoint}?key={key}"
req = urllib.request.Request(
    url,
    data=json.dumps(payload).encode(),
    headers={"Content-Type": "application/json"}
)
try:
    with urllib.request.urlopen(req, timeout=30) as r:
        d = json.loads(r.read())
        t = d["candidates"][0]["content"]["parts"][0]["text"]
        t = re.sub(r"\*\*", "", t)
        t = re.sub(r"^#+\s*", "", t, flags=re.M)
        t = re.sub(r"^[-•]\s*", "", t, flags=re.M)
        print(t.strip())
except Exception as e:
    print("")
PYEOF
    )

    [[ -z "$answer" ]] && send_msg "$cid" "⚠️ Could not get answer right now. Please try again!" && return

    inc_usage "$cid"

    # Save to persistent memory file (survives restarts)
    save_memory "$cid" "user" "$question"
    save_memory "$cid" "assistant" "$answer"

    # Also save to old history for compatibility
    local history; history=$(uget "$cid" "history")
    local hist="${history}
User: ${question}
Bot: ${answer}"
    uset "$cid" "history" "$(echo "$hist" | tail -6)"

    send_msg "$cid" "${answer}

$(usage_note "$cid")"
    log "CHAT $cid: ${question:0:40}"
}

# ──────────────────────────────────────────────────────────────
# EXPLAIN TOPIC
# ──────────────────────────────────────────────────────────────
explain_topic() {
    local cid="$1" topic="$2"
    [[ "$(can_ai "$cid")" == "no" ]] && limit_msg "$cid" && return

    send_msg "$cid" "📖 _Looking up ${topic}..._"

    local name; name=$(uget "$cid" "name")
    local name_ctx=""
    [[ -n "$name" ]] && name_ctx="Address the student as ${name}."

    local sys="You are SmartPal, a brilliant teacher. Explain topics clearly. Always use this EXACT format:

DEFINITION: The real official definition in 1-2 precise sentences.

SIMPLE EXPLANATION: Explain so a 6 year old Nigerian child understands. Use everyday Nigerian examples like mama cooking, NEPA light, going to market, okada, football. Short sentences. Fun and encouraging.

EXAMPLE: One real-life practical example.

Plain text only. No markdown. Follow the format strictly. ${name_ctx}"

    local answer
    answer=$(ask_ai "$sys" "Explain this topic clearly: ${topic}")
    [[ -z "$answer" ]] && send_msg "$cid" "⚠️ Could not explain that. Try again!" && return

    inc_usage "$cid"
    uset "$cid" "last_topic" "$topic"
    send_msg "$cid" "📚 *${topic}*

${answer}

$(usage_note "$cid")
_Did not understand? Say_ *explain again*"
    log "EXPLAIN $cid: $topic"
}

reexplain() {
    local cid="$1"
    local topic; topic=$(uget "$cid" "last_topic")
    [[ -z "$topic" ]] && send_msg "$cid" "What topic should I re-explain? Try /explain TOPIC" && return
    [[ "$(can_ai "$cid")" == "no" ]] && limit_msg "$cid" && return

    send_msg "$cid" "🤔 _Let me try explaining ${topic} differently..._"

    local name; name=$(uget "$cid" "name")
    local name_ctx=""
    [[ -n "$name" ]] && name_ctx="Address the student as ${name}."

    local sys="You are SmartPal, a very patient teacher. The student did NOT understand your previous explanation. Use an EVEN SIMPLER approach. Imagine talking to a 5 year old. Use the most basic Nigerian daily examples. Very short sentences. Be encouraging. ${name_ctx}

Format:
THINK OF IT LIKE THIS: A simple Nigerian comparison or story.
IN SHORT: One sentence — what it basically means.
TRY THIS EXAMPLE: One super simple example.

Plain text only. No markdown."

    local answer
    answer=$(ask_ai "$sys" "Re-explain even more simply: ${topic}")
    [[ -z "$answer" ]] && send_msg "$cid" "⚠️ Could not re-explain. Try again!" && return

    inc_usage "$cid"
    send_msg "$cid" "📚 *${topic} — Simpler Version*

${answer}

$(usage_note "$cid")
_Still confused? Say_ *explain again* _and I will keep trying!_"
}

is_reexplain() {
    local t="${1,,}"
    [[ "$t" == *"don't understand"* || "$t" == *"dont understand"* || \
       "$t" == *"explain again"*    || "$t" == *"re-explain"*      || \
       "$t" == *"simplify"*         || "$t" == *"simpler"*         || \
       "$t" == *"too hard"*         || "$t" == *"confusing"*       || \
       "$t" == *"confused"*         || "$t" == *"break it down"*   || \
       "$t" == *"i no understand"*  || "$t" == *"i no get"*        || \
       "$t" == *"i don't get"*      || "$t" == *"i dont get"*      || \
       "$t" == *"explain more"*     || "$t" == *"more simple"*     ]] && echo "yes" || echo "no"
}

# ──────────────────────────────────────────────────────────────
# MCQ QUIZ SYSTEM
# ──────────────────────────────────────────────────────────────

# Session: topic|total|current|score
quiz_save()  { echo "${2}|${3}|${4}|${5}" > "$USERS_DIR/${1}_qsession"; }
quiz_get()   { local f="$USERS_DIR/${1}_qsession"; [[ -f "$f" ]] && cat "$f" || echo ""; }
quiz_clear() { rm -f "$USERS_DIR/${1}_qsession"; }

start_quiz() {
    local cid="$1" topic="$2"
    [[ -z "$topic" ]] && topic="general knowledge"

    uset "$cid" "qtopic" "$topic"
    uflag_set "$cid" "awaiting_count"

    local name; name=$(uget "$cid" "name")
    local greet=""
    [[ -n "$name" ]] && greet="${name}, "

    send_msg "$cid" "🧠 *SmartPal Quiz*
Topic: *${topic}*

${greet}how many questions do you want?
Choose a number from *1 to 20*

Just type the number. Example: *5*"
}

generate_question() {
    local cid="$1" topic="$2" qnum="$3" total="$4"
    # FIX: retry counter as 5th arg — prevents infinite recursion
    local attempt="${5:-0}"
    if [[ "$attempt" -ge 3 ]]; then
        send_msg "$cid" "⚠️ Could not generate a question after 3 tries. Please try /quiz ${topic} again."
        quiz_clear "$cid"
        rm -f "$QUIZ_FILE"
        return
    fi
    [[ "$(can_ai "$cid")" == "no" ]] && limit_msg "$cid" && return

    send_msg "$cid" "🧠 _Generating question ${qnum} of ${total}..._"

    local name; name=$(uget "$cid" "name")
    local name_ctx=""
    [[ -n "$name" ]] && name_ctx="The student name is ${name}."

    local sys="You are a professional quiz master. Generate ONE multiple choice question. You MUST follow this EXACT format with no deviation:
QUESTION: write the question here
A: first option
B: second option
C: third option
D: fourth option
ANSWER: write only the correct letter (A, B, C, or D)
HINT: one helpful clue that does not give away the answer
EXPLANATION: explain why the correct answer is right. Then briefly say why each wrong option is incorrect.

STRICT RULES:
- Multiple choice ONLY. Never theory or open ended.
- Plain text only. No markdown. No bold. No symbols.
- All 4 options must be plausible.
- Keep explanation under 80 words.
- Make question ${qnum} different from previous questions.
${name_ctx}"

    local prompt
    if [[ "${topic,,}" == *"?"* ]] || \
       [[ "${topic,,}" == "what "* ]] || [[ "${topic,,}" == "who "* ]] || \
       [[ "${topic,,}" == "when "* ]] || [[ "${topic,,}" == "which "* ]] || \
       [[ "${topic,,}" == "how "* ]]  || [[ "${topic,,}" == "why "* ]]; then
        prompt="Convert this into a multiple choice question (question ${qnum} of ${total}): ${topic}"
    else
        prompt="Topic: ${topic}. Create unique MCQ question number ${qnum} of ${total}. Make it different from previous questions."
    fi

    local resp q a h e oa ob oc od
    resp=$(ask_ai "$sys" "$prompt")

    q=$(echo  "$resp" | grep "^QUESTION:"    | head -1 | sed 's/^QUESTION: *//')
    a=$(echo  "$resp" | grep "^ANSWER:"      | head -1 | sed 's/^ANSWER: *//')
    h=$(echo  "$resp" | grep "^HINT:"        | head -1 | sed 's/^HINT: *//')
    e=$(echo  "$resp" | grep "^EXPLANATION:" | head -1 | sed 's/^EXPLANATION: *//')
    oa=$(echo "$resp" | grep "^A:"           | head -1 | sed 's/^A: *//')
    ob=$(echo "$resp" | grep "^B:"           | head -1 | sed 's/^B: *//')
    oc=$(echo "$resp" | grep "^C:"           | head -1 | sed 's/^C: *//')
    od=$(echo "$resp" | grep "^D:"           | head -1 | sed 's/^D: *//')

    if [[ -z "$q" || -z "$a" || -z "$oa" || -z "$ob" ]]; then
        # FIX: pass incremented attempt — no more infinite recursion
        log "QUIZ_FAIL attempt=${attempt} resp_preview=$(echo "$resp" | head -1)"
        sleep 2
        generate_question "$cid" "$topic" "$qnum" "$total" $(( attempt + 1 ))
        return
    fi

    # Save pending quiz — pipe separated
    printf "%s|%s|%s|%s|%s" "$cid" "$a" "$h" "$topic" "$e" > "$QUIZ_FILE"
    inc_usage "$cid"

    send_msg "$cid" "🧠 *Question ${qnum} of ${total}*
Topic: *${topic}*

❓ ${q}

A: ${oa}
B: ${ob}
C: ${oc}
D: ${od}

Type *A*, *B*, *C* or *D* to answer
/hint — get a clue | /skip — skip"
}

check_answer() {
    local cid="$1" ans="$2"
    [[ ! -f "$QUIZ_FILE" ]] && return 1

    local sc ca hint topic expl
    sc=$(cut   -d'|' -f1 "$QUIZ_FILE")
    ca=$(cut   -d'|' -f2 "$QUIZ_FILE")
    hint=$(cut -d'|' -f3 "$QUIZ_FILE")
    topic=$(cut -d'|' -f4 "$QUIZ_FILE")
    expl=$(cut -d'|' -f5 "$QUIZ_FILE")

    [[ "$sc" != "$cid" ]] && return 1
    rm -f "$QUIZ_FILE"

    local correct="no"
    [[ "${ans,,}" == "${ca,,}" ]] && correct="yes"

    local session
    session=$(quiz_get "$cid")

    if [[ -n "$session" ]]; then
        local s_topic s_total s_cur s_score
        s_topic=$(echo "$session" | cut -d'|' -f1)
        s_total=$(echo "$session" | cut -d'|' -f2)
        s_cur=$(echo   "$session" | cut -d'|' -f3)
        s_score=$(echo "$session" | cut -d'|' -f4)

        [[ "$correct" == "yes" ]] && s_score=$(( s_score + 1 ))
        local nxt=$(( s_cur + 1 ))

        if [[ "$correct" == "yes" ]]; then
            send_msg "$cid" "✅ *Correct!* (${s_cur}/${s_total}) 🎉

Correct Answer: *${ca}*

📖 *Why:*
${expl}"
        else
            send_msg "$cid" "❌ *Wrong!* (${s_cur}/${s_total})

Your answer: *${ans}*
Correct answer: *${ca}*

📖 *Why your answer is wrong:*
${expl}"
        fi

        if [[ "$nxt" -gt "$s_total" ]]; then
            quiz_clear "$cid"
            local pct=$(( s_score * 100 / s_total ))
            local grade
            if   [[ "$pct" -ge 80 ]]; then grade="Excellent! 🏆"
            elif [[ "$pct" -ge 60 ]]; then grade="Good job! 👍"
            elif [[ "$pct" -ge 40 ]]; then grade="Keep practicing! 💪"
            else grade="Keep studying! 📚"
            fi
            send_msg "$cid" "🎓 *Quiz Complete!*

Topic: *${s_topic}*
Score: *${s_score} out of ${s_total}* (${pct}%)
Grade: ${grade}

Type /quiz ${s_topic} to try again!"
        else
            quiz_save "$cid" "$s_topic" "$s_total" "$nxt" "$s_score"
            sleep 1
            generate_question "$cid" "$s_topic" "$nxt" "$s_total"
        fi
    else
        # Single question fallback
        if [[ "$correct" == "yes" ]]; then
            send_msg "$cid" "✅ *Correct! Well done!* 🎉

Correct Answer: *${ca}*

📖 *Why:*
${expl}

Type /quiz ${topic} for another!"
        else
            send_msg "$cid" "❌ *Wrong Answer!*

Your answer: *${ans}*
Correct answer: *${ca}*

📖 *Why your answer is wrong:*
${expl}

Type /quiz ${topic} to try again!"
        fi
    fi
    return 0
}

quiz_hint() {
    local cid="$1"
    [[ ! -f "$QUIZ_FILE" ]] && send_msg "$cid" "No active quiz. Type /quiz TOPIC to start!" && return
    local sc h
    sc=$(cut -d'|' -f1 "$QUIZ_FILE")
    h=$(cut  -d'|' -f3 "$QUIZ_FILE")
    [[ "$sc" != "$cid" ]] && send_msg "$cid" "No active quiz for you!" && return
    send_msg "$cid" "💡 *Hint:* ${h}"
}

# ──────────────────────────────────────────────────────────────
# FINANCIAL ADVISOR
# ──────────────────────────────────────────────────────────────
log_expense() {
    local cid="$1" raw="$2"
    local amt cat note
    amt=$(echo  "$raw" | awk '{print $2}')
    cat=$(echo  "$raw" | awk '{print $3}')
    note=$(echo "$raw" | cut -d' ' -f4-)

    if ! [[ "$amt" =~ ^[0-9]+([.][0-9]+)?$ ]]; then
        send_msg "$cid" "Wrong format!
Use: /spent AMOUNT CATEGORY note
Example: /spent 1500 food bought lunch"
        return
    fi

    local uexp="$USERS_DIR/${cid}_expenses.csv"
    [[ ! -f "$uexp" ]] && echo "date,amount,category,note" > "$uexp"
    echo "$(date '+%Y-%m-%d'),${amt},${cat},${note}" >> "$uexp"

    local income spent rem pct
    income=$(uget "$cid" "income"); [[ -z "$income" ]] && income=0
    spent=$(awk -F',' -v m="$(date '+%Y-%m')" \
        'NR>1 && substr($1,1,7)==m {s+=$2} END {printf "%.0f",s+0}' "$uexp")
    rem=$(( income - spent ))
    [[ "$income" -gt 0 ]] && pct=$(( spent * 100 / income )) || pct=0

    local warn=""
    [[ "$income" -gt 0 && "$pct" -ge 90 ]] && \
        warn="🚨 *WARNING:* ${pct}% of income spent! Only N${rem} left. Stop non-essential spending now!"
    [[ "$income" -gt 0 && "$pct" -ge 75 && "$pct" -lt 90 ]] && \
        warn="⚠️ *Careful:* ${pct}% spent. N${rem} remaining. Start cutting back!"
    [[ "$income" -gt 0 && "$pct" -ge 50 && "$pct" -lt 75 ]] && \
        warn="💡 ${pct}% of budget used. N${rem} left."

    send_msg "$cid" "✅ *Expense Logged!*

📅 $(date '+%Y-%m-%d')
💰 Amount: N${amt}
🏷️ Category: ${cat}
📝 Note: ${note}

📊 *This Month:* Spent N${spent} | Remaining N${rem}
${warn}

/summary — full report"
}

show_summary() {
    local cid="$1"
    local income spent rem pct count cats
    local uexp="$USERS_DIR/${cid}_expenses.csv"
    [[ ! -f "$uexp" ]] && echo "date,amount,category,note" > "$uexp"

    income=$(uget "$cid" "income"); [[ -z "$income" ]] && income=0
    spent=$(awk -F',' -v m="$(date '+%Y-%m')" \
        'NR>1 && substr($1,1,7)==m {s+=$2} END {printf "%.0f",s+0}' "$uexp")
    count=$(awk -F',' -v m="$(date '+%Y-%m')" \
        'NR>1 && substr($1,1,7)==m {c++} END {print c+0}' "$uexp")
    cats=$(awk -F',' -v m="$(date '+%Y-%m')" \
        'NR>1 && substr($1,1,7)==m {cat[$3]+=$2} END {for(c in cat) printf "  %s: N%.0f\n",c,cat[c]}' \
        "$uexp")
    rem=$(( income - spent ))
    [[ "$income" -gt 0 ]] && pct=$(( spent * 100 / income )) || pct=0

    local status
    if   [[ "$pct" -ge 90 ]]; then status="🚨 CRITICAL — Almost out of budget!"
    elif [[ "$pct" -ge 75 ]]; then status="⚠️ WARNING — Spending too fast!"
    elif [[ "$pct" -ge 50 ]]; then status="💡 MODERATE — Watch your spending"
    else                            status="✅ GOOD — On track!"
    fi

    local n=$(( income * 50 / 100 ))
    local w=$(( income * 30 / 100 ))
    local s=$(( income * 20 / 100 ))
    local name; name=$(uget "$cid" "name")
    local greet=""
    [[ -n "$name" ]] && greet="${name}'s "

    send_msg "$cid" "📊 *${greet}Financial Report — $(date '+%B %Y')*

💰 Income: N${income}
💸 Spent: N${spent} (${pct}%)
🏦 Remaining: N${rem}
🧾 Transactions: ${count}

${status}

*By Category:*
${cats}

*Budget Targets (50/30/20):*
  🏠 Needs: N${n}
  🎉 Wants: N${w}
  💰 Savings: N${s}

/budget — detailed plan | /setincome — update income"
}

show_budget() {
    local cid="$1"
    local income; income=$(uget "$cid" "income")
    [[ -z "$income" || "$income" == "0" ]] && \
        send_msg "$cid" "Set your income first with /setincome" && return

    local n=$(( income * 50 / 100 ))
    local w=$(( income * 30 / 100 ))
    local s=$(( income * 20 / 100 ))
    local food=$(( n * 40 / 100 ))
    local trnsp=$(( n * 25 / 100 ))
    local rent=$(( n * 35 / 100 ))

    send_msg "$cid" "📊 *Your SmartPal Budget Plan*
Monthly Income: *N${income}*

🏠 *NEEDS (50%) — N${n}*
  Food & groceries: N${food}
  Transport: N${trnsp}
  Rent & bills: N${rent}

🎉 *WANTS (30%) — N${w}*
  Entertainment, eating out, shopping
  Enjoyment that is not essential

💰 *SAVINGS (20%) — N${s}*
  Emergency fund (aim for 3-6 months expenses)
  Investments & future goals

💡 *Top Tips:*
  Pay yourself first — save before you spend
  Track every expense no matter how small
  Cut one want per week to save more
  Review your spending every Sunday

/summary — see how you are doing vs this plan"
}

finance_advice() {
    local cid="$1" q="$2"
    [[ "$(can_ai "$cid")" == "no" ]] && limit_msg "$cid" && return
    send_msg "$cid" "💰 _Thinking about your finances..._"

    local income spent rem
    income=$(uget "$cid" "income"); [[ -z "$income" ]] && income=0
    local uexp="$USERS_DIR/${cid}_expenses.csv"
    [[ ! -f "$uexp" ]] && echo "date,amount,category,note" > "$uexp"
    spent=$(awk -F',' -v m="$(date '+%Y-%m')" \
        'NR>1 && substr($1,1,7)==m {s+=$2} END {printf "%.0f",s+0}' "$uexp")
    rem=$(( income - spent ))
    local name; name=$(uget "$cid" "name")
    local name_ctx=""
    [[ -n "$name" ]] && name_ctx="The user name is ${name}."

    local sys="You are SmartPal, a practical financial advisor for Nigerians. Monthly income: N${income}. Spent this month: N${spent}. Remaining: N${rem}. Give specific actionable Nigerian financial advice. Plain text only. Under 200 words. Be direct and practical. ${name_ctx}"
    local ans; ans=$(ask_ai "$sys" "$q")
    [[ -z "$ans" ]] && send_msg "$cid" "⚠️ Could not get advice right now. Try again!" && return
    inc_usage "$cid"
    send_msg "$cid" "💰 *Financial Advice:*

${ans}

$(usage_note "$cid")"
}

# ──────────────────────────────────────────────────────────────
# TRAINING
# ──────────────────────────────────────────────────────────────
bot_learn() {
    local cid="$1" txt="$2"
    local k="${txt#/teach }"
    echo "[$(date '+%Y-%m-%d')] [${cid}] ${k}" >> "$KNOWLEDGE_FILE"
    send_msg "$cid" "🧠 *Learned!*

_\"${k}\"_

Thank you! The more you teach me the smarter I get 🤖"
}

bot_correct() {
    local cid="$1" txt="$2"
    local c="${txt#/correct }"
    echo "[$(date '+%Y-%m-%d')] [${cid}] CORRECTION: ${c}" >> "$KNOWLEDGE_FILE"
    send_msg "$cid" "✅ *Correction noted!*

_\"${c}\"_

Thank you for helping me improve! 🙏"
}

# ──────────────────────────────────────────────────────────────
# PDF STUDY FEATURE
# ──────────────────────────────────────────────────────────────

# Get how many PDFs user has processed today
get_pdf_usage() {
    local cid="$1" f="$USERS_DIR/${cid}_pdf_usage"
    [[ ! -f "$f" ]] && echo "0" && return
    local d c
    d=$(cut -d'|' -f1 "$f")
    c=$(cut -d'|' -f2 "$f")
    [[ "$d" == "$(date '+%Y-%m-%d')" ]] && echo "$c" || echo "0"
}

inc_pdf_usage() {
    local cid="$1" cur
    cur=$(get_pdf_usage "$cid")
    echo "$(date '+%Y-%m-%d')|$(( cur + 1 ))" > "$USERS_DIR/${cid}_pdf_usage"
}

can_pdf() {
    local cid="$1"
    local used limit
    used=$(get_pdf_usage "$cid")
    if [[ "$(uget "$cid" "boosted")" == "yes" ]]; then
        limit=$PDF_BOOSTED_LIMIT
    else
        limit=$PDF_FREE_LIMIT
    fi
    [[ "$used" -lt "$limit" ]] && echo "yes" || echo "no"
}

get_pdf_page_limit() {
    local cid="$1"
    if [[ "$(uget "$cid" "boosted")" == "yes" ]]; then
        echo "$PDF_BOOSTED_PAGES"
    else
        echo "$PDF_FREE_PAGES"
    fi
}

# Download and process a PDF sent by the user
handle_pdf() {
    local cid="$1" file_id="$2" file_name="$3"

    # Check PDF usage limit
    if [[ "$(can_pdf "$cid")" == "no" ]]; then
        local used limit
        used=$(get_pdf_usage "$cid")
        if [[ "$(uget "$cid" "boosted")" == "yes" ]]; then
            limit=$PDF_BOOSTED_LIMIT
        else
            limit=$PDF_FREE_LIMIT
        fi
        send_msg "$cid" "📵 You have used all *${limit} PDF uploads* for today.

Your limit resets at midnight. Contact @Bazman to get boosted access for more uploads! 🚀"
        return
    fi

    send_msg "$cid" "📄 Got your PDF! Downloading and reading it...

⏳ This may take a moment depending on the file size."

    # Get file path from Telegram
    local file_info file_path
    file_info=$(curl -s "${TG_URL}/getFile?file_id=${file_id}" 2>/dev/null)
    file_path=$(echo "$file_info" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('result',{}).get('file_path',''))" 2>/dev/null)

    if [[ -z "$file_path" ]]; then
        send_msg "$cid" "❌ Could not download the PDF. Please try again."
        return
    fi

    # Download PDF to temp location
    local pdf_tmp="$BOT_DIR/.pdf_${cid}.pdf"
    curl -s "https://api.telegram.org/file/bot${BOT_TOKEN}/${file_path}" -o "$pdf_tmp" 2>/dev/null

    if [[ ! -f "$pdf_tmp" ]]; then
        send_msg "$cid" "❌ Download failed. Please try again."
        return
    fi

    # Install pdfplumber if not available
    python3 -c "import pdfplumber" 2>/dev/null || pip3 install pdfplumber --break-system-packages -q 2>/dev/null

    # Extract text and page count
    local page_limit
    page_limit=$(get_pdf_page_limit "$cid")

    local extracted
    extracted=$(PDF_FILE="$pdf_tmp" PAGE_LIMIT="$page_limit" python3 << 'PYEOF'
import os, sys
pdf_file = os.environ["PDF_FILE"]
page_limit = int(os.environ["PAGE_LIMIT"])
try:
    import pdfplumber
    with pdfplumber.open(pdf_file) as pdf:
        total = len(pdf.pages)
        pages_to_read = min(total, page_limit)
        text = ""
        for i in range(pages_to_read):
            page_text = pdf.pages[i].extract_text()
            if page_text:
                text += f"
--- Page {i+1} ---
{page_text}"
        print(f"PAGES:{total}:{pages_to_read}")
        print(text[:15000])  # Cap at 15000 chars to avoid huge outputs
except Exception as e:
    print(f"ERROR:{e}")
PYEOF
    )

    rm -f "$pdf_tmp"

    if [[ "$extracted" == ERROR:* ]]; then
        send_msg "$cid" "❌ Could not read this PDF. Make sure it is a text-based PDF (not a scanned image).

Tip: PDFs from downloads, handouts typed on a computer work best. Scanned/photo PDFs don't work."
        return
    fi

    # Parse page info
    local total_pages pages_read
    total_pages=$(echo "$extracted" | head -1 | cut -d':' -f2)
    pages_read=$(echo "$extracted" | head -1 | cut -d':' -f3)
    local pdf_text
    pdf_text=$(echo "$extracted" | tail -n +2)

    if [[ -z "$pdf_text" || ${#pdf_text} -lt 50 ]]; then
        send_msg "$cid" "❌ This PDF appears to be a scanned image — I can only read text-based PDFs.

Tip: Try a PDF that was typed/created digitally, not one that was scanned."
        return
    fi

    # Increment PDF usage
    inc_pdf_usage "$cid"
    local pdf_used pdf_left
    pdf_used=$(get_pdf_usage "$cid")
    if [[ "$(uget "$cid" "boosted")" == "yes" ]]; then
        pdf_left=$(( PDF_BOOSTED_LIMIT - pdf_used ))
    else
        pdf_left=$(( PDF_FREE_LIMIT - pdf_used ))
    fi

    # Store PDF text for this user (for follow-up questions)
    printf "%s" "$pdf_text" > "$USERS_DIR/${cid}_pdf_context.txt"
    uset "$cid" "pdf_name" "$file_name"

    send_msg "$cid" "✅ PDF read successfully!

📄 *${file_name}*
📃 Total pages: *${total_pages}*
📖 Pages read: *${pages_read}*
📊 PDF uploads left today: *${pdf_left}*

What do you want me to do with this material?"

    # Show options as keyboard
    RAW_TXT="Choose an option:" RAW_KB="{"inline_keyboard":[[{"text":"🧠 Set MCQ Questions","callback_data":"_pdf_mcq"},{"text":"📝 Set Theory Questions","callback_data":"_pdf_theory"}],[{"text":"📚 Explain Simply","callback_data":"_pdf_explain"},{"text":"📋 Summarize","callback_data":"_pdf_summary"}]]}" RAW_CID="$cid" RAW_URL="$TG_URL" python3 << 'PYEOF'
import os, urllib.request, json
cid = os.environ["RAW_CID"]
txt = os.environ["RAW_TXT"]
kb  = os.environ["RAW_KB"]
url = os.environ["RAW_URL"] + "/sendMessage"
data = json.dumps({"chat_id": cid, "text": txt, "parse_mode": "Markdown", "reply_markup": kb}).encode()
req = urllib.request.Request(url, data=data, headers={"Content-Type": "application/json"})
try: urllib.request.urlopen(req, timeout=10)
except: pass
PYEOF
}

# Process PDF with AI based on user's chosen action
process_pdf_action() {
    local cid="$1" action="$2"

    local ctx_file="$USERS_DIR/${cid}_pdf_context.txt"
    if [[ ! -f "$ctx_file" ]]; then
        send_msg "$cid" "❌ No PDF in memory. Please send a PDF first."
        return
    fi

    local pdf_text pdf_name
    pdf_text=$(cat "$ctx_file")
    pdf_name=$(uget "$cid" "pdf_name")

    [[ "$(can_ai "$cid")" == "no" ]] && limit_msg "$cid" && return

    local instruction system_prompt
    case "$action" in
        mcq)
            send_msg "$cid" "🧠 Generating MCQ questions from *${pdf_name}*...

⏳ Processing the material, please wait."
            system_prompt="You are a professional exam setter. Read the provided study material and generate 10 multiple choice questions based on it. Use EXACTLY this format for each question:

QUESTION: the question here
A: option one
B: option two
C: option three
D: option four
ANSWER: correct letter
EXPLANATION: brief explanation

Number each question 1-10. Only use information from the provided material."
            instruction="Generate 10 MCQ questions from this study material:

${pdf_text}"
            ;;
        theory)
            send_msg "$cid" "📝 Generating theory questions from *${pdf_name}*...

⏳ Processing the material, please wait."
            system_prompt="You are a professional exam setter. Read the provided study material and generate 8 theory/essay questions based on it. For each question also provide a model answer outline. Use this format:

Q1: [question]
Model Answer: [key points to cover]

Make questions that test deep understanding, not just recall."
            instruction="Generate 8 theory questions with model answers from this study material:

${pdf_text}"
            ;;
        explain)
            send_msg "$cid" "📚 Explaining *${pdf_name}* simply...

⏳ Breaking it down for you, please wait."
            system_prompt="You are a brilliant teacher. Read the provided study material and explain it in the simplest possible way. Use Nigerian everyday examples where possible. Structure your explanation as:

OVERVIEW: what this material is about in 2 sentences
KEY POINTS: the 5-7 most important things to know
SIMPLE EXPLANATION: explain the main concepts like you are talking to a secondary school student
REMEMBER THIS: the 3 most important things to remember for exams"
            instruction="Explain this study material simply:

${pdf_text}"
            ;;
        summary)
            send_msg "$cid" "📋 Summarizing *${pdf_name}*...

⏳ Creating your summary, please wait."
            system_prompt="You are an expert study assistant. Read the provided material and create a clear, concise study summary. Structure it as:

TOPIC: main topic
KEY CONCEPTS: bullet points of main ideas
IMPORTANT DETAILS: facts, dates, figures worth remembering
EXAM TIPS: what to focus on for exams
SUMMARY: 3-5 sentence overall summary"
            instruction="Summarize this study material:

${pdf_text}"
            ;;
    esac

    local response
    response=$(ask_ai "$system_prompt" "$instruction")
    inc_usage "$cid"

    if [[ -z "$response" ]]; then
        send_msg "$cid" "❌ AI could not process this material. Please try again."
        return
    fi

    # Split long responses (Telegram has 4096 char limit per message)
    if [[ ${#response} -gt 3800 ]]; then
        local part1 part2
        part1="${response:0:3800}"
        part2="${response:3800}"
        send_msg "$cid" "$part1"
        sleep 1
        send_msg "$cid" "$part2"
    else
        send_msg "$cid" "$response"
    fi

    send_msg "$cid" "

Want to do something else with this PDF?
- Send another PDF to upload a new one
- /quiz TOPIC for a regular quiz
- Type any question about the material and I will answer it"
}

# ──────────────────────────────────────────────────────────────
# HELP & STATUS
# ──────────────────────────────────────────────────────────────
show_help() {
    local cid="$1"
    local used lim rem
    used=$(get_usage "$cid"); lim=$(get_limit "$cid"); rem=$(( lim - used ))

    send_msg "$cid" "👋 *SmartPal — Command Guide*

🤖 *AI CHAT*
  Just type anything — I answer like ChatGPT
  I remember our conversation

📚 *EXPLAIN*
  /explain photosynthesis
  /explain how banks work
  Say _explain again_ if confused

🧠 *QUIZ (MCQ)*
  /quiz biology
  /quiz mathematics
  /quiz Who invented electricity?
  Choose 1-20 questions
  /hint — clue | /skip — skip

💰 *FINANCES*
  /spent 1500 food bought lunch
  /summary — financial report
  /budget — budget plan
  /setincome — set monthly income
  Ask money questions naturally!

☀️ *QUOTES*
  /quote or say _inspire me_

🧑‍🏫 *TEACH THE BOT*
  /teach Lagos is in Southwest Nigeria
  /correct The answer should be XYZ

📋 *ACCOUNT*
  /status — usage today
  /newchat — clear chat history
  /clear — reset expenses

━━━━━━━━━━━━━━━━
🆓 *${rem} of ${lim} free AI actions left today*
Resets at midnight 🌙"
}

show_status() {
    local cid="$1"
    local used lim rem income name
    used=$(get_usage "$cid"); lim=$(get_limit "$cid"); rem=$(( lim - used ))
    income=$(uget "$cid" "income"); [[ -z "$income" ]] && income="Not set"
    name=$(uget "$cid" "name"); [[ -z "$name" ]] && name="Not set"

    send_msg "$cid" "📋 *Your SmartPal Account*

👤 Name: ${name}
🆔 Chat ID: ${cid}
💰 Monthly Income: N${income}

🤖 AI Actions Today: ${used} used
✅ Remaining: ${rem}
📊 Daily Limit: ${lim}
🌙 Resets at midnight

/setincome — update income"
}

# ──────────────────────────────────────────────────────────────
# ADMIN
# ──────────────────────────────────────────────────────────────
admin_cmd() {
    local cid="$1" txt="$2"
    [[ "$cid" != "$ADMIN_CHAT_ID" ]] && \
        send_msg "$cid" "You do not have permission for this." && return

    case "$txt" in
        /boost\ *)
            local t="${txt#/boost }"
            touch "$BOT_DIR/boosted.txt"
            grep -qx "$t" "$BOT_DIR/boosted.txt" || echo "$t" >> "$BOT_DIR/boosted.txt"
            send_msg "$cid" "✅ User ${t} boosted to ${BOOSTED_LIMIT}/day"
            send_msg "$t"   "🎉 Your daily limit increased to *${BOOSTED_LIMIT} AI actions/day*!" 2>/dev/null || true
            ;;
        /unboost\ *)
            local t="${txt#/unboost }"
            grep -v "^${t}$" "$BOT_DIR/boosted.txt" > "$BOT_DIR/boosted.tmp" && \
                mv "$BOT_DIR/boosted.tmp" "$BOT_DIR/boosted.txt" 2>/dev/null || true
            send_msg "$cid" "✅ User ${t} back to ${FREE_LIMIT}/day"
            ;;
        /resetlimit\ *)
            local t="${txt#/resetlimit }"
            echo "$(date '+%Y-%m-%d')|0" > "$USERS_DIR/${t}_usage"
            send_msg "$cid" "✅ Usage reset for ${t}"
            send_msg "$t"   "Your SmartPal daily limit has been reset! 🎉" 2>/dev/null || true
            ;;
        /users)
            local uc kc
            uc=$(ls "$USERS_DIR"/*_usage 2>/dev/null | wc -l)
            kc=$(wc -l < "$KNOWLEDGE_FILE")
            send_msg "$cid" "📊 *SmartPal Stats*
Users tracked: ${uc}
Knowledge entries: ${kc}
Log size: $(wc -l < "$LOG_FILE") lines"
            ;;
        /broadcast\ *)
            local msg="${txt#/broadcast }" cnt=0
            for f in "$USERS_DIR"/*_usage; do
                local uid; uid=$(basename "$f" | sed 's/_usage//')
                send_msg "$uid" "📢 *SmartPal Announcement:*

${msg}" 2>/dev/null || true
                cnt=$(( cnt + 1 ))
            done
            send_msg "$cid" "✅ Broadcast sent to ${cnt} users"
            ;;
        *)
            send_msg "$cid" "Unknown admin command."
            ;;
    esac
}

# ──────────────────────────────────────────────────────────────
# MAIN MESSAGE HANDLER
# ──────────────────────────────────────────────────────────────
handle() {
    local cid="$1" raw="$2"

    # Sanitize input
    local text; text=$(sanitize "$raw")
    local lower="${text,,}"

    # ── COMMAND ROUTING ──────────────────────────────────────
    case "$text" in

        /start)
            local name; name=$(uget "$cid" "name")
            if [[ -n "$name" ]]; then
                send_keyboard "$cid" "👋 Welcome back *${name}!*

Good to see you again — pick what you need below or just type anything 😊"

            else
                uflag_set "$cid" "need_name"
                send_msg "$cid" "👋 *Hello! I am SmartPal!*

Your personal AI assistant for learning and smart money management 🤖

Before we start — *what is your name?* 😊"
            fi
            ;;

        /help)      show_help "$cid" ;;
        /status)    show_status "$cid" ;;
        /quote)     send_quote "$cid" ;;
        /budget)    show_budget "$cid" ;;
        /summary)   show_summary "$cid" ;;
        /newchat)
            uset "$cid" "history" ""
            clear_memory "$cid"
            send_msg "$cid" "🗑️ Conversation cleared! Fresh start 😊 I've forgotten everything — what would you like to talk about?"
            ;;
        /clear)
            local uexp="$USERS_DIR/${cid}_expenses.csv"
            echo "date,amount,category,note" > "$uexp"
            send_msg "$cid" "🗑️ Expenses cleared! Starting fresh ✅"
            ;;
        /hint)      quiz_hint "$cid" ;;

        # PDF action buttons
        _pdf_mcq)     process_pdf_action "$cid" "mcq" ;;
        _pdf_theory)  process_pdf_action "$cid" "theory" ;;
        _pdf_explain) process_pdf_action "$cid" "explain" ;;
        _pdf_summary) process_pdf_action "$cid" "summary" ;;
        /skip)
            rm -f "$QUIZ_FILE"
            quiz_clear "$cid"
            send_msg "$cid" "⏭️ Skipped! Type /quiz TOPIC to start a new quiz."
            ;;
        /quiz)
            start_quiz "$cid" "general knowledge"
            ;;
        /quiz\ *)
            start_quiz "$cid" "${text#/quiz }"
            ;;
        /explain\ *)
            explain_topic "$cid" "${text#/explain }"
            ;;
        /spent\ *)
            log_expense "$cid" "$text"
            ;;
        /setincome)
            uflag_set "$cid" "need_income"
            local cur; cur=$(uget "$cid" "income")
            if [[ -n "$cur" && "$cur" != "0" ]]; then
                send_msg "$cid" "Current income: *N${cur}/month*

Send the new amount to update. Example: *50000*"
            else
                send_msg "$cid" "💰 *Set Your Monthly Income*

This helps SmartPal:
  • Show you exactly how much you can spend per category
  • Warn you when you are overspending
  • Give you a personalised budget plan
  • Track your savings progress

Type your monthly income or allowance in Naira.
Example: *50000*"
            fi
            ;;
        /teach\ *)   bot_learn "$cid" "$text" ;;
        /correct\ *) bot_correct "$cid" "$text" ;;

        # Button tap handlers (inline)
        _btn_quiz)    send_msg "$cid" "🧠 What topic do you want to quiz on?
Type: /quiz TOPIC
Example: /quiz biology" ;;
        _btn_explain) send_msg "$cid" "📚 What topic do you want explained?
Type: /explain TOPIC
Example: /explain photosynthesis" ;;
        _btn_finance) finance_advice "$cid" "give me financial advice" ;;
        _btn_quote)   send_quote "$cid" ;;
        _btn_summary) show_summary "$cid" ;;
        _btn_help)    show_help "$cid" ;;

        # Persistent keyboard button text handlers
        "🧠 Quiz")      send_msg "$cid" "🧠 What topic do you want to quiz on?
Type: /quiz TOPIC
Example: /quiz biology" ;;
        "📚 Explain")   send_msg "$cid" "📚 What topic do you want explained?
Type: /explain TOPIC
Example: /explain photosynthesis" ;;
        "☀️ Quote")    send_quote "$cid" ;;
        "💰 Finance")   finance_advice "$cid" "give me financial advice" ;;
        "📊 Summary")   show_summary "$cid" ;;
        "📋 Budget")    show_budget "$cid" ;;
        "💸 Log Expense") send_msg "$cid" "💸 To log an expense use:
/spent AMOUNT CATEGORY note

Example: /spent 1500 food bought lunch" ;;
        "📈 Status")    show_status "$cid" ;;
        "❓ Help")      show_help "$cid" ;;

        /boost\ * | /unboost\ * | /resetlimit\ * | /users | /broadcast\ *)
            admin_cmd "$cid" "$text"
            ;;

        /*)
            send_msg "$cid" "❓ Unknown command. Type /help to see all commands!"
            ;;

        # ── NATURAL LANGUAGE ROUTING ─────────────────────────
        *)
            # STEP 1 — Waiting for quiz count
            if [[ "$(uflag_check "$cid" "awaiting_count")" == "yes" ]]; then
                if [[ "$text" =~ ^[0-9]+$ ]] && \
                   [[ "$text" -ge 1 ]] && [[ "$text" -le 20 ]]; then
                    uflag_clear "$cid" "awaiting_count"
                    local topic; topic=$(uget "$cid" "qtopic")
                    quiz_save "$cid" "$topic" "$text" "1" "0"
                    local name; name=$(uget "$cid" "name")
                    local greet=""
                    [[ -n "$name" ]] && greet="${name}, "
                    send_msg "$cid" "🧠 Starting *${text}-question* MCQ quiz on *${topic}*!
${greet}Good luck! 💪"
                    sleep 1
                    generate_question "$cid" "$topic" "1" "$text"
                else
                    send_msg "$cid" "Please enter a number between *1 and 20*.
Example: *5*"
                fi
                return
            fi

            # STEP 2 — Pending quiz answer
            if [[ -f "$QUIZ_FILE" ]]; then
                local sc; sc=$(cut -d'|' -f1 "$QUIZ_FILE")
                if [[ "$sc" == "$cid" ]]; then
                    check_answer "$cid" "$text"
                    return
                fi
            fi

            # STEP 3 — Waiting for name
            if [[ "$(uflag_check "$cid" "need_name")" == "yes" ]]; then
                uflag_clear "$cid" "need_name"
                uset "$cid" "name" "$text"
                send_keyboard "$cid" "Nice to meet you *${text}!* 🎉

I am SmartPal — your personal AI assistant for:
  🤖 Answering any question
  📚 Explaining any topic simply
  🧠 MCQ quizzes on any subject
  💰 Tracking your money and giving financial advice
  ☀️ Daily motivation

You are all set! Use the buttons below or just type anything 😊"
                return
            fi

            # STEP 4 — Waiting for income
            if [[ "$(uflag_check "$cid" "need_income")" == "yes" ]]; then
                if [[ "$text" =~ ^[0-9]+$ ]]; then
                    uflag_clear "$cid" "need_income"
                    uset "$cid" "income" "$text"
                    local n=$(( text * 50 / 100 ))
                    local w=$(( text * 30 / 100 ))
                    local s=$(( text * 20 / 100 ))
                    local name; name=$(uget "$cid" "name")
                    send_msg "$cid" "✅ *Income Set — N${text}/month*

Your recommended budget, *${name}*:

🏠 *Needs (50%): N${n}*
   Food, transport, rent, bills

🎉 *Wants (30%): N${w}*
   Entertainment, shopping, eating out

💰 *Savings (20%): N${s}*
   Emergency fund and investments

You are all set! Just talk to me naturally 😊
Type /help to see everything I can do!"
                else
                    send_msg "$cid" "Please send just the number. Example: *50000*"
                fi
                return
            fi

            # STEP 5 — Re-explain request
            if [[ "$(is_reexplain "$lower")" == "yes" ]]; then
                reexplain "$cid"
                return
            fi

            # STEP 6 — Quote request
            if [[ "$lower" == *"quote"*       || "$lower" == *"motivat"* || \
                  "$lower" == *"inspire"*     || "$lower" == *"inspiration"* || \
                  "$lower" == *"encourage"*   || "$lower" == *"wisdom"* ]]; then
                send_quote "$cid"
                return
            fi

            # STEP 7 — Finance question
            if [[ "$lower" == *"how to save"*     || "$lower" == *"investment"*    || \
                  "$lower" == *"financial advice"* || "$lower" == *"money advice"*  || \
                  "$lower" == *"how to invest"*    || "$lower" == *"budget advice"* || \
                  "$lower" == *"should i spend"*   || "$lower" == *"save money"* ]]; then
                finance_advice "$cid" "$text"
                return
            fi

            # STEP 8 — Explain (natural phrasing)
            if [[ "$lower" == "explain "* || "$lower" == "what is "* || \
                  "$lower" == "what are "* || "$lower" == "how does "* || \
                  "$lower" == "how do "* ]]; then
                explain_topic "$cid" "$text"
                return
            fi

            # STEP 9 — Everything else goes to AI chat
            ai_chat "$cid" "$text"
            ;;
    esac
}

# ──────────────────────────────────────────────────────────────
# CRON MODE — send daily quote
# Usage: bash bot.sh --quote CHAT_ID
# Cron:  0 7 * * * /bin/bash ~/telegram_bot/bot.sh --quote 8382934002
# ──────────────────────────────────────────────────────────────
if [[ "${1:-}" == "--quote" && -n "${2:-}" ]]; then
    send_quote "$2"
    exit 0
fi

# ──────────────────────────────────────────────────────────────
# STARTUP
# ──────────────────────────────────────────────────────────────
# Validate required environment variables
if [[ -z "$BOT_TOKEN" ]]; then
    echo "ERROR: BOT_TOKEN is not set. Set it as an environment variable."
    exit 1
fi
if [[ -z "$GROQ_API_KEY" ]]; then
    echo "ERROR: GROQ_API_KEY is not set. Set it as an environment variable."
    exit 1
fi

echo "========================================"
echo "  SmartPal v3.0 — RUNNING"
echo "  Owner : @Bazman"
echo "  Time  : $(date '+%Y-%m-%d %H:%M:%S')"
echo "  Limit : ${FREE_LIMIT} AI actions/day"
echo "  BOT_DIR: ${BOT_DIR}"
echo "========================================"
log "SmartPal v3.0 started"

# Register Telegram command menu on startup
register_commands

# ──────────────────────────────────────────────────────────────
# IMAGE UNDERSTANDING
# ──────────────────────────────────────────────────────────────
handle_image() {
    local cid="$1" file_id="$2" caption="$3"

    [[ "$(can_ai "$cid")" == "no" ]] && limit_msg "$cid" && return

    send_msg "$cid" "🔍 Looking at your image..."

    # Get file path
    local file_info file_path
    file_info=$(curl -s "${TG_URL}/getFile?file_id=${file_id}" 2>/dev/null)
    file_path=$(echo "$file_info" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('result',{}).get('file_path',''))" 2>/dev/null)

    if [[ -z "$file_path" ]]; then
        send_msg "$cid" "❌ Could not access the image. Please try again."
        return
    fi

    # Download image
    local img_tmp="$BOT_DIR/.img_${cid}.jpg"
    curl -s "https://api.telegram.org/file/bot${BOT_TOKEN}/${file_path}" -o "$img_tmp" 2>/dev/null

    # Convert to base64 for Groq vision
    local img_b64
    img_b64=$(python3 -c "import base64; print(base64.b64encode(open('${img_tmp}','rb').read()).decode())" 2>/dev/null)
    rm -f "$img_tmp"

    if [[ -z "$img_b64" ]]; then
        send_msg "$cid" "❌ Could not process the image. Please try again."
        return
    fi

    # Use the caption as the question if provided, else describe
    local user_question="${caption:-Describe this image in detail. If it contains text, read it. If it contains a question or problem, answer it.}"

    # Call Gemini Vision
    local response
    response=$(IMG_B64="$img_b64" USER_Q="$user_question" \
               GEMINI_KEY="$GEMINI_API_KEY" python3 << 'PYEOF'
import os, json, urllib.request, re
b64      = os.environ["IMG_B64"]
question = os.environ["USER_Q"]
key      = os.environ["GEMINI_KEY"]

payload = {
    "contents": [{
        "parts": [
            {"inline_data": {"mime_type": "image/jpeg", "data": b64}},
            {"text": question}
        ]
    }],
    "generationConfig": {"maxOutputTokens": 1000}
}

url = f"https://generativelanguage.googleapis.com/v1beta/models/gemini-1.5-flash:generateContent?key={key}"
req = urllib.request.Request(
    url,
    data=json.dumps(payload).encode(),
    headers={"Content-Type": "application/json"}
)
try:
    with urllib.request.urlopen(req, timeout=30) as r:
        d = json.loads(r.read())
        t = d["candidates"][0]["content"]["parts"][0]["text"]
        t = re.sub(r"\*\*", "", t)
        print(t.strip())
except Exception as e:
    print(f"ERROR:{e}")
PYEOF
    )

    inc_usage "$cid"

    if [[ "$response" == ERROR:* || -z "$response" ]]; then
        send_msg "$cid" "❌ Could not analyse the image. Try again or send a clearer image."
        return
    fi

    send_msg "$cid" "🖼️ *Image Analysis:*

${response}"
}

# ──────────────────────────────────────────────────────────────
# VOICE MESSAGE HANDLING
# ──────────────────────────────────────────────────────────────
handle_voice() {
    local cid="$1" file_id="$2"

    [[ "$(can_ai "$cid")" == "no" ]] && limit_msg "$cid" && return

    send_msg "$cid" "🎤 Got your voice message! Transcribing..."

    # Get file path
    local file_info file_path
    file_info=$(curl -s "${TG_URL}/getFile?file_id=${file_id}" 2>/dev/null)
    file_path=$(echo "$file_info" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('result',{}).get('file_path',''))" 2>/dev/null)

    if [[ -z "$file_path" ]]; then
        send_msg "$cid" "❌ Could not access the voice message. Please try again."
        return
    fi

    # Download voice file
    local voice_tmp="$BOT_DIR/.voice_${cid}.ogg"
    curl -s "https://api.telegram.org/file/bot${BOT_TOKEN}/${file_path}" -o "$voice_tmp" 2>/dev/null

    # Transcribe using Groq Whisper
    local transcript
    transcript=$(VOICE_FILE="$voice_tmp" GROQ_KEY="$GROQ_API_KEY" python3 << 'PYEOF'
import os, urllib.request
voice_file = os.environ["VOICE_FILE"]
key = os.environ["GROQ_KEY"]
try:
    with open(voice_file, "rb") as f:
        audio_data = f.read()

    import urllib.parse, json
    boundary = "----FormBoundary7MA4YWxkTrZu0gW"
    body = (
        f"--{boundary}
"
        f"Content-Disposition: form-data; name="file"; filename="audio.ogg"
"
        f"Content-Type: audio/ogg

"
    ).encode() + audio_data + (
        f"
--{boundary}
"
        f"Content-Disposition: form-data; name="model"

"
        f"whisper-large-v3-turbo
"
        f"--{boundary}--
"
    ).encode()

    req = urllib.request.Request(
        "https://api.groq.com/openai/v1/audio/transcriptions",
        data=body,
        headers={
            "Authorization": f"Bearer {key}",
            "Content-Type": f"multipart/form-data; boundary={boundary}"
        }
    )
    with urllib.request.urlopen(req, timeout=30) as r:
        d = json.loads(r.read())
        print(d.get("text", ""))
except Exception as e:
    print(f"ERROR:{e}")
PYEOF
    )

    rm -f "$voice_tmp"

    if [[ "$transcript" == ERROR:* || -z "$transcript" ]]; then
        send_msg "$cid" "❌ Could not transcribe. Please speak clearly and try again."
        return
    fi

    send_msg "$cid" "🎤 *You said:* "${transcript}""

    # Now process the transcribed text as a normal message
    inc_usage "$cid"
    handle "$cid" "$transcript"
}

# ──────────────────────────────────────────────────────────────
# WEB SEARCH
# ──────────────────────────────────────────────────────────────
web_search_context() {
    local query="$1"
    # Use DuckDuckGo instant answers (free, no API key needed)
    local result
    result=$(SEARCH_Q="$query" python3 << 'PYEOF'
import os, urllib.request, urllib.parse, json, re
q = os.environ["SEARCH_Q"]
encoded = urllib.parse.quote(q)
url = f"https://api.duckduckgo.com/?q={encoded}&format=json&no_html=1&skip_disambig=1"
try:
    req = urllib.request.Request(url, headers={"User-Agent": "SmartPalBot/1.0"})
    with urllib.request.urlopen(req, timeout=10) as r:
        d = json.loads(r.read())
        abstract = d.get("AbstractText", "")
        answer = d.get("Answer", "")
        related = [t.get("Text","") for t in d.get("RelatedTopics",[])[:3] if t.get("Text")]
        result = ""
        if answer: result += f"Quick answer: {answer}
"
        if abstract: result += f"{abstract}
"
        if related: result += "Related: " + " | ".join(related[:2])
        print(result[:1500] if result.strip() else "NO_RESULTS")
except:
    print("NO_RESULTS")
PYEOF
    )
    echo "$result"
}

needs_web_search() {
    local text="${1,,}"
    # Topics that likely need current/real-world info
    [[ "$text" == *"today"*       ]] && echo "yes" && return
    [[ "$text" == *"current"*     ]] && echo "yes" && return
    [[ "$text" == *"latest"*      ]] && echo "yes" && return
    [[ "$text" == *"news"*        ]] && echo "yes" && return
    [[ "$text" == *"price of"*    ]] && echo "yes" && return
    [[ "$text" == *"dollar"*      ]] && echo "yes" && return
    [[ "$text" == *"exchange rate"* ]] && echo "yes" && return
    [[ "$text" == *"who won"*      ]] && echo "yes" && return
    [[ "$text" == *"what happened"* ]] && echo "yes" && return
    [[ "$text" == *"naira"*       ]] && echo "yes" && return
    echo "no"
}

# ──────────────────────────────────────────────────────────────
# PERSISTENT MEMORY (save conversation across restarts)
# ──────────────────────────────────────────────────────────────
save_memory() {
    local cid="$1" role="$2" text="$3"
    local mem_file="$USERS_DIR/${cid}_memory.txt"
    # Keep last 20 exchanges (40 lines)
    echo "${role}|${text}" >> "$mem_file"
    local line_count
    line_count=$(wc -l < "$mem_file" 2>/dev/null || echo 0)
    if [[ "$line_count" -gt 40 ]]; then
        tail -40 "$mem_file" > "$mem_file.tmp" && mv "$mem_file.tmp" "$mem_file"
    fi
}

load_memory() {
    local cid="$1"
    local mem_file="$USERS_DIR/${cid}_memory.txt"
    [[ ! -f "$mem_file" ]] && echo "[]" && return
    python3 << PYEOF
import json
msgs = []
try:
    with open("$mem_file") as f:
        for line in f.read().strip().split("\n"):
            if "|" in line:
                role, text = line.split("|", 1)
                if role in ("user", "assistant"):
                    msgs.append({"role": role, "content": text})
except: pass
print(json.dumps(msgs[-20:]))
PYEOF
}

clear_memory() {
    local cid="$1"
    rm -f "$USERS_DIR/${cid}_memory.txt"
}

# ──────────────────────────────────────────────────────────────
# POLLING LOOP
# ──────────────────────────────────────────────────────────────
while true; do
    OFFSET=$(get_offset)
    UPDATES=$(curl -s --max-time 30 "${TG_URL}/getUpdates?offset=${OFFSET}&timeout=10" 2>/dev/null || echo '{"ok":false,"result":[]}')
    COUNT=$(echo "$UPDATES" | grep -o '"update_id"' | wc -l || echo "0")

    if [[ "$COUNT" -gt 0 ]]; then
        for (( i=0; i<COUNT; i++ )); do
            UPD_ID=$(parse_update "$UPDATES" "$i" "uid")
            CID=$(parse_update "$UPDATES" "$i" "cid")
            TXT=$(parse_update "$UPDATES" "$i" "text")

            # Detect PDF, image, voice from this update
            MEDIA_DATA=$(PU_JSON="$UPDATES" PU_IDX="$i" python3 << 'PYEOF'
import os, json
try:
    d = json.loads(os.environ["PU_JSON"])
    r = d.get("result", [])
    idx = int(os.environ["PU_IDX"])
    msg = r[idx].get("message", {})

    # PDF
    doc = msg.get("document", {})
    if doc.get("mime_type") == "application/pdf":
        print(f"PDF|{doc['file_id']}|{doc.get('file_name','document.pdf')}")

    # Image (photo)
    elif msg.get("photo"):
        photos = msg["photo"]
        best = max(photos, key=lambda p: p.get("file_size", 0))
        caption = msg.get("caption", "")
        print(f"IMAGE|{best['file_id']}|{caption}")

    # Voice message
    elif msg.get("voice"):
        v = msg["voice"]
        print(f"VOICE|{v['file_id']}|{v.get('duration',0)}")

    # Audio file
    elif msg.get("audio"):
        a = msg["audio"]
        print(f"VOICE|{a['file_id']}|{a.get('duration',0)}")

    # Callback query (button tap)
    elif r[idx].get("callback_query"):
        cb = r[idx]["callback_query"]
        print(f"CB|{cb.get('data','')}|")
    else:
        print("TEXT||")
except Exception as e:
    print("TEXT||")
PYEOF
            )

            MEDIA_TYPE=$(echo "$MEDIA_DATA" | cut -d'|' -f1)
            MEDIA_ID=$(echo "$MEDIA_DATA"   | cut -d'|' -f2)
            MEDIA_EXTRA=$(echo "$MEDIA_DATA" | cut -d'|' -f3-)

            # Callback button tap — treat as text
            if [[ "$MEDIA_TYPE" == "CB" && -n "$MEDIA_ID" ]]; then
                TXT="$MEDIA_ID"
            fi

            if [[ -n "$UPD_ID" && -n "$CID" ]]; then
                case "$MEDIA_TYPE" in
                    PDF)
                        echo "[$(date '+%H:%M:%S')] Chat ${CID}: [PDF] ${MEDIA_EXTRA}"
                        handle_pdf "$CID" "$MEDIA_ID" "$MEDIA_EXTRA"
                        ;;
                    IMAGE)
                        echo "[$(date '+%H:%M:%S')] Chat ${CID}: [IMAGE]"
                        handle_image "$CID" "$MEDIA_ID" "$MEDIA_EXTRA"
                        ;;
                    VOICE)
                        echo "[$(date '+%H:%M:%S')] Chat ${CID}: [VOICE]"
                        handle_voice "$CID" "$MEDIA_ID"
                        ;;
                    *)
                        if [[ -n "$TXT" ]]; then
                            echo "[$(date '+%H:%M:%S')] Chat ${CID}: ${TXT}"
                            handle "$CID" "$TXT"
                        fi
                        ;;
                esac
                save_offset $(( UPD_ID + 1 ))
            fi
        done
    fi

    sleep 1
done
