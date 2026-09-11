#!/usr/bin/env bash
# PROJECT_LOCAL_SELF_RESEARCH_NOT_GOOGLE_OFFICIAL
#
# coralnpu-gesture 仓库两端同步助手
#
# 仓库：https://github.com/SteveGuo1726/coralnpu-gesture  （public）
#   Ubuntu 端：/home/steveguo/coralnpu-gesture        （.git 是 gitfile -> .git-local）
#   Windows 端：/mnt/c/Users/SteveGuo/Documents/coralnpu-gesture  （WSL 从这个路径操作）
#
# ---------------------------------------------------------------------------
# 凭据现实（2026-09-12 实测）
# ---------------------------------------------------------------------------
#   * Ubuntu 端 / WSL  : SSH 密钥 ~/.ssh/id_ed25519 可用
#                        -> `Hi SteveGuo1726! You've successfully authenticated`
#                        -> **推送走这里**
#   * Windows 端 git   : 无 SSH 密钥、无 credential helper
#                        -> 只能用 HTTPS **拉取**（仓库公开，匿名可读）
#                        -> 无法推送（除非之后配 PAT）
#
# 所以 remote 的 URL 是故意分开的：
#     fetch = https://github.com/...   （两端都能拉）
#     push  = git@github.com:...       （由 WSL/Ubuntu 推送）
# 命令：git remote set-url --push origin git@github.com:SteveGuo1726/coralnpu-gesture.git
#
# ---------------------------------------------------------------------------
# 推荐工作流（避免"一端已跟踪、另一端未跟踪"的 pull 冲突）
# ---------------------------------------------------------------------------
#   内容只在一端产生时，用对应方向；不要两端各自 commit 同一批文件。
#
#   A. 在 Ubuntu 端改了代码
#        bash sync_repo.sh ubuntu-push
#        bash sync_repo.sh win-pull
#
#   B. 在 Windows 端写了文档
#        bash sync_repo.sh win-to-ubuntu     # 拷进 Ubuntu 工作树
#        bash sync_repo.sh ubuntu-push       # 由 Ubuntu 提交并推送
#        bash sync_repo.sh win-pull          # Windows 拉回（会被 git clean 替换）
#
#   C. 只看看有没有新东西
#        bash sync_repo.sh win-pull
#
# ---------------------------------------------------------------------------
# ⚠️ 实测坑（2026-09-12 凌晨踩到，务必看）
# ---------------------------------------------------------------------------
# 1. **同一个本机 agent 环境里，git 的 ref 锁写入会被拦**：
#    `git fetch` 报 `* [new branch] main -> origin/main`，但 `.git/refs/remotes/`
#    下没有文件、`git rev-parse origin/main` 说 "not a commit"。
#    手动往 `.git/refs/...` 写文件是正常的 → 是 git 的 锁文件+rename 流程被拦。
#    **后果**：连续两次 commit 可能导致本地分支与远端**分叉**而不自知。
#    **对策**：每次操作后用 `git fetch && git rev-parse refs/remotes/origin/main`
#    显式确认，不要只看 `git log`。
#
# 2. **"提交成功"不可信，必须回读内容**：
#    曾出现 `git commit` 报成功、但提交里**没有**实际改动（`--stat` 只有别的文件）。
#    **对策**：提交后一律 `git show --stat HEAD`，并且从远端 `git show
#    refs/remotes/origin/main:<path>` 回读关键文件确认。
#
# 3. **分叉后的修复姿势**（保留工作树里真正想要的改动）：
#      cp <要保留的文件> /tmp/keep
#      git fetch origin
#      git reset --hard refs/remotes/origin/main
#      cp /tmp/keep <原路径>
#      git add <原路径> && git commit && git push
#    **不要**用 merge/rebase 去接分叉——这个仓库的内容差异很小，
#    直接以远端为基线重做一次更干净。
#
# 4. **永远只有一端 commit**。两端各自 commit 同一批文件必然分叉；
#    Windows 端不具备推送能力，所以以 Ubuntu 为提交端。
# ---------------------------------------------------------------------------

set -uo pipefail
export PATH=/usr/bin:/bin

R=/home/steveguo/coralnpu-gesture
W=/mnt/c/Users/SteveGuo/Documents/coralnpu-gesture
AUTHOR_NAME=SteveGuo1726
AUTHOR_MAIL=175320411+SteveGuo1726@users.noreply.github.com
GIT="git -c user.name=$AUTHOR_NAME -c user.email=$AUTHOR_MAIL"

die() { echo "ERROR: $*" >&2; exit 2; }

# ---------------------------------------------------------------------------
# Windows 端 -> Ubuntu 工作树（只拷字面文件，不动 git 状态）
# ---------------------------------------------------------------------------
case "${1:-}" in

win-to-ubuntu)
  [ -d "$W/gesture_project" ] || die "找不到 Windows 工作区 $W"
  echo "== 拷贝 Windows 端新增/修改的文档与脚本到 Ubuntu 工作树 =="
  # 文档
  mkdir -p "$R/gesture_project/docs"
  for f in "$W"/gesture_project/docs/*.md; do
    [ -f "$f" ] || continue
    cp -f "$f" "$R/gesture_project/docs/" && echo "  docs  <- $(basename "$f")"
  done
  # board_zcu104 下的脚本/约束文件（不含子目录递归之外的东西）
  D="$R/gesture_project/innovation_npu/board_zcu104"
  mkdir -p "$D/plnx" "$D/scripts"
  for f in "$W"/gesture_project/innovation_npu/board_zcu104/*; do
    [ -f "$f" ] || continue
    cp -f "$f" "$D/" && echo "  board <- $(basename "$f")"
  done
  for f in "$W"/gesture_project/innovation_npu/board_zcu104/plnx/*; do
    [ -f "$f" ] || continue
    cp -f "$f" "$D/plnx/" && echo "  plnx  <- $(basename "$f")"
  done
  for f in "$W"/gesture_project/innovation_npu/board_zcu104/scripts/*; do
    [ -f "$f" ] || continue
    cp -f "$f" "$D/scripts/" && echo "  script<- $(basename "$f")"
  done
  echo "完成。接着用 ubuntu-push 提交。"
  ;;

# ---------------------------------------------------------------------------
# Ubuntu 端：暂存 -> 提交 -> 推送
# ---------------------------------------------------------------------------
ubuntu-push)
  cd "$R" || die "cd $R"
  echo "== 待提交内容（仅 gesture_project/ 下的改动，避免误加 60G 构建产物）=="
  $GIT add gesture_project/ 2>&1 | tail -3
  if git diff --cached --quiet; then
    echo "没有需要提交的改动。"
  else
    git diff --cached --stat | tail -15
    MSG="${2:-chore: sync from $(hostname) $(date +%F_%H:%M)}"
    $GIT commit -q -m "$MSG" || die "commit 失败"
    echo "已提交：$(git log --oneline -1)"
  fi
  echo
  echo "== 待推送 =="
  git log --oneline origin/main..main 2>/dev/null || true
  echo
  echo "== 推送 =="
  timeout 300 git push origin main 2>&1 | tail -6
  ;;

# ---------------------------------------------------------------------------
# Windows 端（WSL 操作 /mnt/c）：清理未跟踪副本 -> 快进 -> 报告
# ---------------------------------------------------------------------------
win-pull)
  cd "$W" || die "cd $W"
  echo "== fetch =="
  git fetch origin 2>&1 | tail -3
  echo "远端 main = $(git rev-parse --short origin/main 2>/dev/null)"
  echo
  # 未跟踪文件如果会被即将拉取的提交覆盖，pull 会拒绝；先清掉（它们会被还原）
  for p in gesture_project/docs gesture_project/innovation_npu/board_zcu104; do
    [ -e "$p" ] || continue
    n=$(git clean -fdn "$p" 2>/dev/null | wc -l)
    [ "$n" -gt 0 ] && { echo "清理 $p 下 $n 项未跟踪副本（随后由 git 还原）"; git clean -fd "$p" >/dev/null; }
  done
  echo
  echo "== 快进 =="
  git merge --ff-only origin/main 2>&1 | tail -4
  echo
  echo "HEAD = $(git rev-parse --short HEAD)"
  echo "跟踪文件数 = $(git ls-files | wc -l)"
  git status --short | head -10
  ;;

status)
  echo "--- Windows 端 ---"
  git -C "$W" rev-parse --short HEAD 2>/dev/null || echo "(不是 git 仓库)"
  git -C "$W" status -sb 2>/dev/null | head -3
  echo
  echo "--- Ubuntu 端 ---"
  git -C "$R" rev-parse --short HEAD 2>/dev/null || echo "(不是 git 仓库)"
  git -C "$R" status -sb 2>/dev/null | head -3
  echo
  echo "--- 远端 ---"
  GIT_TERMINAL_PROMPT=0 git ls-remote "$R" main 2>/dev/null \
    | awk '{printf "main = %.7s\n", $1}'
  echo
  echo "--- 严格一致性判定（必须显式 fetch 后再比，见文件头坑 1）---"
  git -C "$W" fetch origin >/dev/null 2>&1
  git -C "$R" fetch origin >/dev/null 2>&1
  wh=$(git -C "$W" rev-parse HEAD 2>/dev/null)
  rh=$(git -C "$R" rev-parse HEAD 2>/dev/null)
  oh=$(git -C "$R" rev-parse refs/remotes/origin/main 2>/dev/null)
  printf 'windows=%s\nubuntu =%s\nremote =%s\n' "${wh:0:7}" "${rh:0:7}" "${oh:0:7}"
  if [ -n "$oh" ] && [ "$wh" = "$oh" ] && [ "$rh" = "$oh" ]; then
    echo "=> 三端一致 OK"
  else
    echo "=> !! 不一致 —— 检查是否分叉，按文件头「坑 3」修复"
    echo "--- 本地领先远端 ---"; git -C "$R" log --oneline refs/remotes/origin/main..HEAD 2>/dev/null | head -5
    echo "--- 远端领先本地 ---"; git -C "$R" log --oneline HEAD..refs/remotes/origin/main 2>/dev/null | head -5
  fi
  ;;

*)
  sed -n '1,60p' "$0"
  ;;
esac
