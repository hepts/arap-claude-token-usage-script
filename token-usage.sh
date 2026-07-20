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
# 料金は 2026-07-20 時点（ブログ記事準拠）。DISABLE_PROMPT_CACHING でも usage は正しく取れます。
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
import json, os, sys, datetime

DETAIL = os.environ.get("TU_DETAIL", "")
LIMIT  = int(os.environ.get("TU_LIMIT", "0") or 0)
JSON_OUT = os.environ.get("TU_JSON", "0") == "1"

# 料金表 (USD / MTok) 2026-07-20 時点。write5m=5分cache作成, write1h=1時間cache作成
PRICING = {
    "claude-opus-4-8":       {"in": 5.0,  "out": 25.0, "w5": 6.25,  "w1": 10.0, "read": 0.5},
    "claude-sonnet-5":       {"in": 2.0,  "out": 10.0, "w5": 2.50,  "w1": 4.0,  "read": 0.2},  # ~2026/8/31 の料金
    "claude-fable-5":        {"in": 10.0, "out": 50.0, "w5": 12.50, "w1": 20.0, "read": 1.0},
    "claude-haiku-4-5":      {"in": 1.0,  "out": 5.0,  "w5": 1.25,  "w1": 2.0,  "read": 0.1},
    # 旧 Opus（4.6以降は値下げ後の Opus 料金で共通、記事本文の記載に準拠）
    "claude-opus-4-7":       {"in": 5.0,  "out": 25.0, "w5": 6.25,  "w1": 10.0, "read": 0.5},
    "claude-opus-4-6":       {"in": 5.0,  "out": 25.0, "w5": 6.25,  "w1": 10.0, "read": 0.5},
    # ※ claude-sonnet-4-6 等それ以前のモデルは料金未確認のため意図的に未登録（"⚠料金不明" 表示）
}

# コスト計算対象外（Claude Code が内部生成する擬似メッセージ等）。料金0・警告なし
FREE_MODELS = {"<synthetic>", "unknown", None}

def price_for(model):
    if model in FREE_MODELS:
        return {"in":0,"out":0,"w5":0,"w1":0,"read":0}
    if model in PRICING:
        return PRICING[model]
    # バージョン付き (例: claude-haiku-4-5-20251001) を前方一致で吸収
    for k, v in PRICING.items():
        if model.startswith(k):
            return v
    return None

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
    seen_ids = set()        # message.id の重複(ストリーミング分割)を排除

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
                mid = msg.get("id")
                if mid and mid in seen_ids:
                    continue
                if mid:
                    seen_ids.add(mid)

                model = msg.get("model", "unknown")
                is_side = d.get("isSidechain", False)
                msg_count += 1
                if is_side:
                    side_count += 1

                acc = new_acc()
                add_usage(acc, usage)
                for k in total:
                    total[k] += acc[k]
                pm = per_model.setdefault(model, new_acc())
                for k in pm:
                    pm[k] += acc[k]

                if DETAIL:
                    detail_rows.append({
                        "ts": ts, "model": model, "side": is_side,
                        "acc": acc, "cost": cost(acc, price_for(model)),
                    })
    except OSError:
        continue

    if msg_count == 0:
        continue

    total_cost = sum(cost(pm, price_for(m)) for m, pm in per_model.items())
    unknown_models = [m for m in per_model if price_for(m) is None]

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
              f"{a['w5']:>9} {a['w1']:>9} {a['read']:>9} {r['cost']:>10.4f}")
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
