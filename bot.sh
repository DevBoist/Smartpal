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
#     Financial advisor (income, budget, spending alerts)
#     Expense tracker
#     Motivational quotes (/quote works)
#     Trainable (/teach /correct)
#     Usage limit (20 free AI actions/day)
#     Admin tools (boost, reset, broadcast)
#     Telegram command menu (sidebar)
#     Security hardened (input sanitization)
# ================================================================

set -o errexit
set -o nounset
set -o pipefail

# ──────────────────────────────────────────────────────────────
# CONFIGURATION — supports env vars for Railway deployment
# ──────────────────────────────────────────────────────────────
BOT_TOKEN="${BOT_TOKEN:-}"
GROQ_API_KEY="${GROQ_API_KEY:-}"
ADMIN_CHAT_ID="${ADMIN_CHAT_ID:-8382934002}"
ADMIN_USERNAME="@Bazman"

FREE_LIMIT=20
BOOSTED_LIMIT=100

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
[[ ! -f "$EXPENSES_FILE" ]] && echo "date,amount,category,note" > "$EXPENSES_FILE"

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

    # Write to temp files — avoids all JSON escaping issues
    printf "%s" "$system_msg" > "$BOT_DIR/.sys.tmp"
    printf "%s" "$user_msg"   > "$BOT_DIR/.usr.tmp"

    local payload
    payload=$(python3 - << 'PYEOF'
import json, sys
with open(sys.argv[1]) as f: sys_msg = f.read().strip()
with open(sys.argv[2]) as f: usr_msg = f.read().strip()
print(json.dumps({
    "model": "llama-3.1-8b-instant",
    "messages": [
        {"role": "system", "content": sys_msg},
        {"role": "user",   "content": usr_msg}
    ],
    "max_tokens": 700,
    "temperature": 0.7
}))
PYEOF
    "$BOT_DIR/.sys.tmp" "$BOT_DIR/.usr.tmp" 2>/dev/null)

    [[ -z "$payload" ]] && echo "" && return

    local raw
    raw=$(curl -s -X POST "$GROQ_URL" \
        -H "Authorization: Bearer ${GROQ_API_KEY}" \
        -H "Content-Type: application/json" \
        -d "$payload" 2>/dev/null)

    python3 - << 'PYEOF'
import sys, json, re
try:
    d = json.loads(sys.argv[1])
    t = d["choices"][0]["message"]["content"]
    t = re.sub(r'\*\*','',t); t = re.sub(r'#+\s*','',t)
    t = re.sub(r'^[-•]\s*','',t,flags=re.M)
    print(t.strip())
except: print("")
PYEOF
    "$raw" 2>/dev/null
}

# ──────────────────────────────────────────────────────────────
# PARSE TELEGRAM UPDATES — using python3 reliably
# ──────────────────────────────────────────────────────────────
parse_update() {
    local json="$1" idx="$2" field="$3"
    python3 - << 'PYEOF'
import sys, json
try:
    d = json.loads(sys.argv[1])
    r = d.get("result", [])
    i = int(sys.argv[2])
    f = sys.argv[3]
    if i >= len(r): print(""); sys.exit()
    u = r[i]
    if   f == "uid":  print(u.get("update_id", ""))
    elif f == "cid":  print(u.get("message",{}).get("chat",{}).get("id",""))
    elif f == "text": print(u.get("message",{}).get("text",""))
    else: print("")
except: print("")
PYEOF
    "$json" "$idx" "$field" 2>/dev/null
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

    local name learned history name_ctx extra hist_ctx
    name=$(uget "$cid" "name")
    learned=$(tail -10 "$KNOWLEDGE_FILE" 2>/dev/null | sed 's/\[.*\] //' || echo "")
    history=$(uget "$cid" "history")
    [[ -n "$name" ]]    && name_ctx="The user's name is ${name}. Use their name naturally." || name_ctx=""
    [[ -n "$learned" ]] && extra="Facts users taught you (use if relevant): ${learned}" || extra=""
    [[ -n "$history" ]] && hist_ctx="Recent conversation: ${history}" || hist_ctx=""

    local sys="You are SmartPal, a brilliant friendly AI assistant for Nigerians on Telegram. Answer any question on any topic. Be conversational and warm. Use plain text only — no markdown symbols. Keep answers under 220 words. Use Naira (N) for money. Be honest if you do not know something. ${name_ctx} ${extra} ${hist_ctx}"

    local answer
    answer=$(ask_ai "$sys" "$question")
    [[ -z "$answer" ]] && send_msg "$cid" "⚠️ Could not get answer right now. Please try again!" && return

    inc_usage "$cid"
    # Save last 3 exchanges
    local hist="${history}
User: ${question}
Bot: ${answer}"
    uset "$cid" "history" "$(echo "$hist" | tail -6)"
    send_msg "$cid" "🤖 ${answer}

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
        send_msg "$cid" "⚠️ Question generation failed. Trying again..."
        sleep 1
        generate_question "$cid" "$topic" "$qnum" "$total"
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

    echo "$(date '+%Y-%m-%d'),${amt},${cat},${note}" >> "$EXPENSES_FILE"

    local income spent rem pct
    income=$(uget "$cid" "income"); [[ -z "$income" ]] && income=0
    spent=$(awk -F',' -v m="$(date '+%Y-%m')" \
        'NR>1 && substr($1,1,7)==m {s+=$2} END {printf "%.0f",s+0}' "$EXPENSES_FILE")
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

    income=$(uget "$cid" "income"); [[ -z "$income" ]] && income=0
    spent=$(awk -F',' -v m="$(date '+%Y-%m')" \
        'NR>1 && substr($1,1,7)==m {s+=$2} END {printf "%.0f",s+0}' "$EXPENSES_FILE")
    count=$(awk -F',' -v m="$(date '+%Y-%m')" \
        'NR>1 && substr($1,1,7)==m {c++} END {print c+0}' "$EXPENSES_FILE")
    cats=$(awk -F',' -v m="$(date '+%Y-%m')" \
        'NR>1 && substr($1,1,7)==m {cat[$3]+=$2} END {for(c in cat) printf "  %s: N%.0f\n",c,cat[c]}' \
        "$EXPENSES_FILE")
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
    spent=$(awk -F',' -v m="$(date '+%Y-%m')" \
        'NR>1 && substr($1,1,7)==m {s+=$2} END {printf "%.0f",s+0}' "$EXPENSES_FILE")
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
                send_msg "$cid" "👋 Welcome back *${name}!*

Good to see you again! What can I help you with?
Type /help to see all I can do 😊"
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
            send_msg "$cid" "🗑️ Conversation history cleared! Fresh start 😊"
            ;;
        /clear)
            echo "date,amount,category,note" > "$EXPENSES_FILE"
            send_msg "$cid" "🗑️ Expenses cleared! Starting fresh ✅"
            ;;
        /hint)      quiz_hint "$cid" ;;
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
                uflag_set "$cid" "need_income"
                send_msg "$cid" "Nice to meet you *${text}!* 🎉

I am SmartPal — your personal AI assistant for:
  🤖 Answering any question
  📚 Explaining any topic simply
  🧠 MCQ quizzes on any subject
  💰 Tracking your money and giving financial advice
  ☀️ Daily motivation

One more thing to set up your financial advisor:

💰 *What is your monthly income or allowance?*

Type the amount in Naira. Example: *50000*

This helps me give you smart budget advice and spending alerts!"
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
echo "========================================"
echo "  SmartPal v3.0 — RUNNING"
echo "  Owner : @Bazman"
echo "  Time  : $(date '+%Y-%m-%d %H:%M:%S')"
echo "  Limit : ${FREE_LIMIT} AI actions/day"
echo "========================================"
log "SmartPal v3.0 started"

# Register Telegram command menu on startup
register_commands

# ──────────────────────────────────────────────────────────────
# POLLING LOOP
# ──────────────────────────────────────────────────────────────
while true; do
    OFFSET=$(get_offset)
    UPDATES=$(curl -s "${TG_URL}/getUpdates?offset=${OFFSET}&timeout=10" 2>/dev/null || echo '{"ok":false,"result":[]}')
    COUNT=$(echo "$UPDATES" | grep -o '"update_id"' | wc -l)

    if [[ "$COUNT" -gt 0 ]]; then
        for (( i=0; i<COUNT; i++ )); do
            UID=$(parse_update "$UPDATES" "$i" "uid")
            CID=$(parse_update "$UPDATES" "$i" "cid")
            TXT=$(parse_update "$UPDATES" "$i" "text")

            if [[ -n "$UID" && -n "$CID" && -n "$TXT" ]]; then
                echo "[$(date '+%H:%M:%S')] Chat ${CID}: ${TXT}"
                handle "$CID" "$TXT"
                save_offset $(( UID + 1 ))
            fi
        done
    fi

    sleep 1
done
