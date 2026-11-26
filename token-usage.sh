#!/usr/bin/env bash
#
# token-usage.sh - Claude Code の JSONL ログからセッション毎のトークン消費量とコストを集計する
#
# 使い方:
#   ./token-usage.sh                     # カレントディレクトリのプロジェクトの全セッション
#   ./token-usage.sh -a                  # 全プロジェクトの全セッション
#   ./token-usage.sh -n 5                # 直近5セッションだけ
#   ./token-usage.sh -p <project-dir>    # ~/.claude/projects/ 配下のプロジェクト名を指定
#   ./token-usage.sh -d <session-id>     # 指定セッションをメッセージ単位で詳細表示
#   ./token-usage.sh <session-id|path>   # 指定セッションのみ集計
#   ./token-usage.sh --json              # 集計結果を JSON で出力
#
# 料金は 2026-11-26 時点の公式料金表準拠。DISABLE_PROMPT_CACHING でも usage は正しく取れます。
#
# bash 専用（process substitution / mapfile を使うため）。
# `sh script.sh` で起動されると macOS では bash 3.2 の POSIX モードになり
# process substitution が無効化されるため、通常の bash で再実行する。
if [ -z "${BASH_VERSION:-}" ] || case ":${SHELLOPTS:-}:" in *:posix:*) true ;; *) false ;; esac; then
  exec bash "$0" "$@"
fi

set -euo pipefail

PROJECTS_DIR="${HOME}/.claude/projects"

# --- 引数パース --------------------------------------------------------------
SCAN_ALL=0
LIMIT=0
DETAIL=""
PROJECT=""
JSON_OUT=0
TARGET=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    -a|--all)     SCAN_ALL=1; shift ;;
    -n|--limit)   LIMIT="${2:-0}"; shift 2 ;;
    -p|--project) PROJECT="${2:-}"; shift 2 ;;
    -d|--detail)  DETAIL="${2:-}"; shift 2 ;;
    --json)       JSON_OUT=1; shift ;;
    -h|--help)
      sed -n '2,14p' "$0" | sed 's/^# \{0,1\}//'
      exit 0 ;;
    *)            TARGET="$1"; shift ;;
  esac
done

# --- 対象ファイルの決定 ------------------------------------------------------
# cwd からプロジェクトディレクトリ名を導出
# Claude Code の命名規則: パス中の英数字以外(/ . 空白 等)をすべて - に置換
cwd_to_project() {
  echo "$1" | sed 's/[^a-zA-Z0-9]/-/g'
}

resolve_files() {
  local files=()
  if [[ -n "$TARGET" ]]; then
    if [[ -f "$TARGET" ]]; then
      files+=("$TARGET")
    else
      # セッションID として全プロジェクトから探す
      while IFS= read -r f; do files+=("$f"); done \
        < <(find "$PROJECTS_DIR" -name "${TARGET}*.jsonl" 2>/dev/null)
    fi
  elif [[ -n "$DETAIL" ]]; then
    while IFS= read -r f; do files+=("$f"); done \
      < <(find "$PROJECTS_DIR" -name "${DETAIL}*.jsonl" 2>/dev/null)
  elif [[ $SCAN_ALL -eq 1 ]]; then
    while IFS= read -r f; do files+=("$f"); done \
      < <(find "$PROJECTS_DIR" -name '*.jsonl' 2>/dev/null)
  else
    local pdir
    if [[ -n "$PROJECT" ]]; then
      pdir="${PROJECTS_DIR}/${PROJECT}"
    else
      pdir="${PROJECTS_DIR}/$(cwd_to_project "$PWD")"
    fi
    if [[ -d "$pdir" ]]; then
      while IFS= read -r f; do files+=("$f"); done \
        < <(find "$pdir" -maxdepth 1 -name '*.jsonl' 2>/dev/null)
    fi
  fi
  printf '%s\n' "${files[@]}"
}

mapfile -t FILES < <(resolve_files)

if [[ ${#FILES[@]} -eq 0 || -z "${FILES[0]}" ]]; then
  echo "対象の JSONL が見つかりませんでした。" >&2
  echo "  カレント: $PWD" >&2
  echo "  探索先:   ${PROJECTS_DIR}/$(cwd_to_project "$PWD")" >&2
  echo "  -a で全プロジェクト、-p でプロジェクト名指定ができます。" >&2
  exit 1
fi

# --- 集計本体（Python） ------------------------------------------------------
export TU_DETAIL="$DETAIL"
export TU_LIMIT="$LIMIT"
export TU_JSON="$JSON_OUT"

python3 - "${FILES[@]}" <<'PYEOF'
import json, os, re, sys, datetime

DETAIL = os.environ.get("TU_DETAIL", "")
LIMIT  = int(os.environ.get("TU_LIMIT", "0") or 0)
JSON_OUT = os.environ.get("TU_JSON", "0") == "1"

# Pricing (USD / MTok) as of 2026-11-26, from https://platform.claude.com/docs/en/about-claude/pricing
# w5 = 5-minute cache write, w1 = 1-hour cache write, read = cache read (hit)
def _p(i, o, w5, w1, r):
    return {"in": i, "out": o, "w5": w5, "w1": w1, "read": r}

PRICING = {
    "claude-fable-5-2":  _p(8.0,  40.0, 10.0,  16.0, 0.20),
    "claude-mythos-5-2": _p(8.0,  40.0, 10.0,  16.0, 0.20),
    "claude-fable-5-1":  _p(10.0, 50.0, 12.50, 20.0, 0.25),
    "claude-mythos-5-1": _p(10.0, 50.0, 12.50, 20.0, 0.25),
    "claude-fable-5":    _p(10.0, 50.0, 12.50, 20.0, 1.00),
    "claude-mythos-5":   _p(10.0, 50.0, 12.50, 20.0, 1.00),
    "claude-opus-5-5":   _p(4.0,  20.0, 5.0,   8.0,  0.20),
    "claude-opus-5":     _p(5.0,  25.0, 6.25,  10.0, 0.50),
    "claude-opus-4-8":   _p(5.0,  25.0, 6.25,  10.0, 0.50),
    "claude-opus-4-7":   _p(5.0,  25.0, 6.25,  10.0, 0.50),
    "claude-opus-4-6":   _p(5.0,  25.0, 6.25,  10.0, 0.50),
    "claude-opus-4-5":   _p(5.0,  25.0, 6.25,  10.0, 0.50),
    "claude-opus-4-1":   _p(15.0, 75.0, 18.75, 30.0, 1.50),
    "claude-opus-4":     _p(15.0, 75.0, 18.75, 30.0, 1.50),
    "claude-sonnet-5-5": _p(2.0,  10.0, 2.50,  4.0,  0.10),
    "claude-sonnet-5":   _p(2.0,  10.0, 2.50,  4.0,  0.20),
    "claude-sonnet-4-6": _p(3.0,  15.0, 3.75,  6.0,  0.30),
    "claude-sonnet-4-5": _p(3.0,  15.0, 3.75,  6.0,  0.30),
    "claude-sonnet-4":   _p(3.0,  15.0, 3.75,  6.0,  0.30),
    "claude-haiku-5-5":  _p(0.10, 0.50, 0.125, 0.20, 0.01),  # prompt <= 100K tokens
    "claude-haiku-4-5":  _p(1.0,  5.0,  1.25,  2.0,  0.10),
}

# Haiku 5.5 is priced by prompt length: a request whose prompt (input + cache write
# + cache read) is over 100,000 tokens pays these prices for all of its tokens.
LONG_PROMPT_THRESHOLD = 100_000
LONG_PROMPT_PRICING = {
    "claude-haiku-5-5":  _p(0.50, 2.50, 0.625, 1.0,  0.05),
}

# Fast mode (usage.speed == "fast") input/output prices. Cache prices are derived by
# applying the usual cache multipliers on top of the fast input price.
FAST_PRICING = {
    "claude-fable-5-2":  {"in": 16.0, "out": 80.0},
    "claude-mythos-5-2": {"in": 16.0, "out": 80.0},
    "claude-opus-5-5":   {"in": 8.0,  "out": 40.0},
    "claude-opus-5":     {"in": 10.0, "out": 50.0},
    "claude-opus-4-8":   {"in": 10.0, "out": 50.0},
}

# inference_geo "us" applies a 1.1x multiplier (Claude 4.6 and later; earlier
# models reject the parameter, so it never appears in their logs)
US_GEO_MULTIPLIER = 1.1

# コスト計算対象外（Claude Code が内部生成する擬似メッセージ等）。料金0・警告なし
FREE_MODELS = {"<synthetic>", "unknown", None}
ZERO = _p(0, 0, 0, 0, 0)

def normalize_model(model):
    # Strip a context-window suffix (claude-opus-5-5[1m]), a Bedrock-style prefix
    # (global.anthropic.claude-opus-5-5) and a date snapshot suffix (-20251001).
    m = re.sub(r"\[[^\]]*\]$", "", model)
    m = re.sub(r"^(?:[a-z]+\.)?anthropic\.", "", m)
    m = re.sub(r"-\d{8}$", "", m)
    return m

def price_for_request(model, acc, speed=None, geo=None):
    """Price for one request after long-prompt, fast-mode and geo modifiers.

    Returns (price, warning); price is None when the cost cannot be computed.
    The model is matched exactly after normalization: a prefix match would let
    claude-sonnet-5-5 silently borrow claude-sonnet-5's price.
    """
    if model in FREE_MODELS:
        return ZERO, None
    key = normalize_model(model)
    base = PRICING.get(key)
    if base is None:
        return None, "料金不明"
    p = base
    prompt_tokens = acc["in"] + acc["w5"] + acc["w1"] + acc["read"]
    if key in LONG_PROMPT_PRICING and prompt_tokens > LONG_PROMPT_THRESHOLD:
        p = LONG_PROMPT_PRICING[key]
    if speed == "fast":
        fp = FAST_PRICING.get(key)
        if fp is None:
            return None, "fast料金不明"
        read_mult = base["read"] / base["in"]
        p = _p(fp["in"], fp["out"], fp["in"] * 1.25, fp["in"] * 2.0, fp["in"] * read_mult)
    if geo == "us":
        p = {k: v * US_GEO_MULTIPLIER for k, v in p.items()}
    return p, None

def cost(u, p):
    if p is None:
        return 0.0
    w5 = u["w5"]; w1 = u["w1"]
    return (
        u["in"]   * p["in"]
        + u["out"] * p["out"]
        + w5       * p["w5"]
        + w1       * p["w1"]
        + u["read"] * p["read"]
    ) / 1_000_000

def new_acc():
    return {"in":0,"out":0,"w5":0,"w1":0,"read":0}

def add_usage(acc, usage):
    acc["in"]   += usage.get("input_tokens", 0)
    acc["out"]  += usage.get("output_tokens", 0)
    acc["read"] += usage.get("cache_read_input_tokens", 0)
    cc = usage.get("cache_creation") or {}
    w5 = cc.get("ephemeral_5m_input_tokens")
    w1 = cc.get("ephemeral_1h_input_tokens")
    if w5 is None and w1 is None:
        # 内訳が無い古い形式は cache_creation_input_tokens を 5m 扱い
        acc["w5"] += usage.get("cache_creation_input_tokens", 0)
    else:
        acc["w5"] += w5 or 0
        acc["w1"] += w1 or 0

def fmt(n):
    return f"{n:,}"

sessions = []
files = sys.argv[1:]

for path in files:
    sid = os.path.splitext(os.path.basename(path))[0]
    project = os.path.basename(os.path.dirname(path))
    total = new_acc()
    per_model = {}          # model -> acc
    msg_count = 0
    side_count = 0
    first_ts = last_ts = None
    first_prompt = None
    detail_rows = []
    # Streaming writes several lines per message.id; earlier lines carry partial
    # output_tokens, so keep the last line's usage (and the first line's timestamp).
    messages = {}           # message.id (or line key) -> record, in first-seen order

    try:
        with open(path, encoding="utf-8") as fh:
            for line in fh:
                line = line.strip()
                if not line:
                    continue
                try:
                    d = json.loads(line)
                except json.JSONDecodeError:
                    continue

                ts = d.get("timestamp")
                if ts:
                    first_ts = first_ts or ts
                    last_ts = ts

                # 最初のユーザープロンプト（ラベル用）
                if first_prompt is None and d.get("type") == "user":
                    msg = d.get("message", {})
                    c = msg.get("content")
                    if isinstance(c, str):
                        first_prompt = c
                    elif isinstance(c, list):
                        for part in c:
                            if isinstance(part, dict) and part.get("type") == "text":
                                first_prompt = part.get("text"); break

                if d.get("type") != "assistant":
                    continue
                msg = d.get("message", {})
                usage = msg.get("usage")
                if not usage:
                    continue
                mid = msg.get("id") or f"_line{len(messages)}"
                rec = messages.get(mid)
                if rec is None:
                    messages[mid] = rec = {"ts": ts}
                rec["usage"] = usage
                rec["model"] = msg.get("model", "unknown")
                rec["side"] = d.get("isSidechain", False)
    except OSError:
        continue

    total_cost = 0.0
    unknown_models = []
    for rec in messages.values():
        model, usage = rec["model"], rec["usage"]
        msg_count += 1
        if rec["side"]:
            side_count += 1

        acc = new_acc()
        add_usage(acc, usage)
        for k in total:
            total[k] += acc[k]
        pm = per_model.setdefault(model, new_acc())
        for k in pm:
            pm[k] += acc[k]

        price, warn = price_for_request(model, acc, usage.get("speed"),
                                        usage.get("inference_geo"))
        c = cost(acc, price)
        total_cost += c
        if warn and model not in unknown_models:
            unknown_models.append(model)

        if DETAIL:
            detail_rows.append({
                "ts": rec["ts"], "model": model, "side": rec["side"],
                "acc": acc, "cost": c, "warn": warn,
            })

    if msg_count == 0:
        continue

    sessions.append({
        "sid": sid, "project": project, "path": path,
        "total": total, "per_model": per_model,
        "cost": total_cost, "msg_count": msg_count, "side_count": side_count,
        "first_ts": first_ts, "last_ts": last_ts,
        "first_prompt": first_prompt, "detail_rows": detail_rows,
        "models": sorted(per_model.keys()), "unknown_models": unknown_models,
    })

# 新しい順（last_ts）
sessions.sort(key=lambda s: s["last_ts"] or "", reverse=True)
if LIMIT > 0 and not DETAIL:
    sessions = sessions[:LIMIT]

# ---- JSON 出力 ----
if JSON_OUT:
    out = []
    for s in sessions:
        out.append({
            "session_id": s["sid"], "project": s["project"],
            "last_ts": s["last_ts"], "messages": s["msg_count"],
            "sidechain_messages": s["side_count"],
            "models": s["models"], "tokens": s["total"],
            "cost_usd": round(s["cost"], 6),
        })
    print(json.dumps(out, ensure_ascii=False, indent=2))
    sys.exit(0)

# ---- 詳細表示（-d） ----
if DETAIL:
    if not sessions:
        print("該当セッションが見つかりませんでした。", file=sys.stderr); sys.exit(1)
    s = sessions[0]
    print(f"\n■ セッション詳細: {s['sid']}")
    print(f"  project : {s['project']}")
    print(f"  期間    : {s['first_ts']} 〜 {s['last_ts']}")
    print(f"  モデル  : {', '.join(s['models'])}")
    print(f"  メッセージ数: {s['msg_count']} (うちサブエージェント {s['side_count']})\n")
    hdr = f"{'#':>3} {'time':<8} {'model':<18} {'in':>8} {'out':>8} {'w5m':>9} {'w1h':>9} {'read':>9} {'cost$':>10}"
    print(hdr); print("-" * len(hdr))
    for i, r in enumerate(s["detail_rows"], 1):
        t = r["ts"][11:19] if r["ts"] else ""
        a = r["acc"]
        tag = "*" if r["side"] else " "
        print(f"{i:>3}{tag}{t:<8} {r['model']:<18} {a['in']:>8} {a['out']:>8} "
              f"{a['w5']:>9} {a['w1']:>9} {a['read']:>9} {r['cost']:>10.4f}"
              + (f" ⚠{r['warn']}" if r["warn"] else ""))
    t = s["total"]
    print("-" * len(hdr))
    print(f"{'':>3} {'TOTAL':<8} {'':<18} {t['in']:>8} {t['out']:>8} "
          f"{t['w5']:>9} {t['w1']:>9} {t['read']:>9} {s['cost']:>10.4f}")
    print("\n  * = サブエージェント(sidechain)")
    print("  w5m=5分cache作成 / w1h=1時間cache作成 / read=cache読み取り\n")
    sys.exit(0)

# ---- 一覧表示（デフォルト） ----
if not sessions:
    print("集計対象のメッセージがありませんでした。", file=sys.stderr); sys.exit(1)

grand = new_acc(); grand_cost = 0.0
print()
hdr = (f"{'session':<10} {'last (UTC)':<20} {'model':<16} "
       f"{'in':>9} {'out':>9} {'cache_w':>10} {'cache_r':>10} {'msg':>4} {'cost$':>9}")
print(hdr); print("-" * len(hdr))
for s in sessions:
    t = s["total"]
    when = (s["last_ts"] or "")[:19].replace("T", " ")
    model_label = s["models"][0].replace("claude-", "") if len(s["models"]) == 1 \
        else f"{len(s['models'])}種"
    cache_w = t["w5"] + t["w1"]
    warn = " ⚠料金不明" if s["unknown_models"] else ""
    print(f"{s['sid'][:8]:<10} {when:<20} {model_label:<16} "
          f"{fmt(t['in']):>9} {fmt(t['out']):>9} {fmt(cache_w):>10} {fmt(t['read']):>10} "
          f"{s['msg_count']:>4} {s['cost']:>9.4f}{warn}")
    for k in grand:
        grand[k] += t[k]
    grand_cost += s["cost"]

print("-" * len(hdr))
cache_w = grand["w5"] + grand["w1"]
print(f"{'TOTAL':<10} {str(len(sessions))+' sessions':<20} {'':<16} "
      f"{fmt(grand['in']):>9} {fmt(grand['out']):>9} {fmt(cache_w):>10} {fmt(grand['read']):>10} "
      f"{'':>4} {grand_cost:>9.4f}")
print(f"\n  cache_w = cache作成(5分+1時間の合計) / cache_r = cache読み取り")
print(f"  詳細は  ./token-usage.sh -d <session-id>  で確認できます\n")
PYEOF
