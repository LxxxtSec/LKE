#!/bin/bash

# ===============================
# Git 自动提交脚本
# Kernel Exploit Learning Repo
# ===============================

set -e

# 当前目录
REPO_DIR=$(pwd)

echo "[+] Repository: $REPO_DIR"


# 检查是否是 git 仓库
if [ ! -d ".git" ]; then
    echo "[-] Error: 当前目录不是 Git 仓库"
    exit 1
fi


# 获取当前分支
BRANCH=$(git branch --show-current)

echo "[+] Current branch: $BRANCH"


# 拉取远程更新
echo "[+] Fetch remote..."

git fetch origin


echo "[+] Merge remote changes..."

git pull origin $BRANCH --allow-unrelated-histories --no-rebase || {
    echo ""
    echo "[-] Merge conflict detected"
    echo "请手动解决冲突后重新运行"
    exit 1
}


# 查看变化

echo "[+] Checking changes..."

git status


# 添加所有文件

echo "[+] Adding files..."

git add .


# 判断是否有变化

if git diff --cached --quiet; then
    echo "[+] No changes to commit"
    exit 0
fi


# 自动生成提交信息

TIME=$(date "+%Y-%m-%d %H:%M:%S")

MESSAGE="update learning notes $TIME"


echo "[+] Commit message:"
echo "$MESSAGE"


git commit -m "$MESSAGE"


# 推送

echo "[+] Push to GitHub..."

git push origin $BRANCH


echo ""
echo "==============================="
echo " Upload Success!"
echo "==============================="
