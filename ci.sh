#!/bin/bash
# 云端这一侧的外壳（明文：公开仓库里只有本文件、工作流和一个加密块 payload.bin）。
# 本文件不含任何与项目有关的名字：解开加密块 → 运行里面的驱动（.ci/run.sh，自动查找）→ 把结果加密成 .bin 上传。
# 加密块格式：前 16 字节 IV ＋ AES-256-CBC(PKCS7) 密文 ＋ 末尾 32 字节 HMAC-SHA256（over IV＋密文）。
# 密钥 SK：128 个十六进制字符——前 64 个是 AES 密钥（32 字节），后 64 个按 ASCII 取字节当 HMAC 的密钥。
# 屏幕上只打印 e1、e2 这样的代号（不含任何内容）：公开仓库的运行记录任何人都能看。
set -u

die() { echo "$1"; exit 1; }

k_check() {
  [ "${#SK}" -eq 128 ] || die e1
  AESK=${SK:0:64}
  MACK=${SK:64:64}
}

# dec <加密文件> <输出>
dec() {
  f=$1; o=$2
  [ -s "$f" ] || die e2
  sz=$(wc -c < "$f" | tr -d ' ')
  body=$((sz - 32))
  [ "$body" -gt 16 ] || die e2
  head -c "$body" "$f" > _b 2>/dev/null || die e2
  tail -c 32 "$f" > _m 2>/dev/null || die e2
  openssl dgst -sha256 -hmac "$MACK" -binary _b > _m2 2>/dev/null || die e3
  cmp -s _m _m2 || die e4
  iv=$(head -c 16 _b | od -An -tx1 -v | tr -d ' \n')
  tail -c +17 _b > _c 2>/dev/null || die e2
  openssl enc -d -aes-256-cbc -K "$AESK" -iv "$iv" -in _c -out "$o" 2>/dev/null || die e5
  rm -f _b _m _m2 _c
}

# enc <明文> <输出>
enc() {
  f=$1; o=$2
  openssl rand 16 > _iv 2>/dev/null || die e6
  iv=$(od -An -tx1 -v < _iv | tr -d ' \n')
  openssl enc -aes-256-cbc -K "$AESK" -iv "$iv" -in "$f" -out _c 2>/dev/null || die e6
  cat _iv _c > _b || die e6
  openssl dgst -sha256 -hmac "$MACK" -binary _b > _m 2>/dev/null || die e6
  cat _b _m > "$o" || die e6
  rm -f _iv _c _b _m
}

# 解开加密块到 w/
unseal() {
  k_check
  dec payload.bin _p.tgz
  rm -rf w
  mkdir -p w || die e7
  tar -xzf _p.tgz -C w 2>/dev/null || die e7
  rm -f _p.tgz
  find w -type f \( -name '*.sh' -o -name '*.command' \) -exec chmod +x {} + 2>/dev/null
}

# 载荷里的驱动 .ci/run.sh（自动查找，这里不写项目的目录名）；再解开附加包（有才有：本机另带的小文件）
driver() {
  DRV=$(find w -maxdepth 3 -type f -path '*/.ci/run.sh' 2>/dev/null | head -n 1)
  [ -n "$DRV" ] || die e10
  if [ -s extra.bin ]; then
    dec extra.bin _x.tgz
    tar -xzf _x.tgz -C "$(dirname "$DRV")/.." 2>/dev/null || die e11
    rm -f _x.tgz
  fi
}

# 打包用的 tar：Windows 机器上用 Git 带的 GNU tar，pax 格式、UTF-8 区域——中文文件名以 UTF-8 写进 pax 头的 path，
# 本机的 tar 按 UTF-8 读，不会乱码（不加 --format=pax 时只写原始字节，本机按 GBK 猜成乱码；
# 换用系统自带的 tar.exe 在英文系统的机器上遇到中文名会以失败退出——e8，一份结果都带不回来）
tarc() {
  case "$(uname -s)" in
    MINGW*|MSYS*|CYGWIN*) LC_ALL=C.UTF-8 tar --format=pax "$@" ;;
    *) COPYFILE_DISABLE=1 tar "$@" ;; # macOS 的 tar 会把扩展属性另存成 ._ 开头的文件（崩溃报告带扩展属性），不要
  esac
}

# 把一个文件夹打包加密成 o/<名字>.bin（打包后原件删掉，机器上不留明文）
seal_out() {
  name=$1; dir=$2
  [ -d "$dir" ] || return 0
  # 空的不封装：下载到加密块就说明这一样东西真的产出了（编译失败时没有程序包）
  if [ -z "$(ls -A "$dir" 2>/dev/null)" ]; then rm -rf "$dir"; return 0; fi
  # 万一打包失败：把 tar 的报错写进这一份结果里，再用最普通的方式打一次——宁可文件名乱码，也要把结果带回来
  if ! tarc -czf _o.tgz -C "$dir" . 2>_tarerr.txt; then
    cp _tarerr.txt "$dir/打包警告.txt" 2>/dev/null
    COPYFILE_DISABLE=1 tar -czf _o.tgz -C "$dir" . 2>/dev/null || die e8
  fi
  rm -f _tarerr.txt
  mkdir -p o
  enc _o.tgz "o/$name.bin"
  rm -f _o.tgz
  rm -rf "$dir"
}

# 前一步被取消（任务超时）时，请驱动把还没收进记录的东西补进去（要不要补由驱动自己判断；最多 60 秒）
collect() {
  CD=$(find w -maxdepth 3 -type f -path '*/.ci/run.sh' 2>/dev/null | head -n 1)
  [ -n "$CD" ] || return 0
  bash "$CD" collect "$1" >> out/log/驱动输出.txt 2>&1 &
  cpid=$!
  (sleep 60; kill -9 "$cpid" 2>/dev/null) >/dev/null 2>&1 &
  wait "$cpid" 2>/dev/null
  return 0
}

mkdir -p out/log
case "${1:-}" in
  1) # 编译机：解开 → 编译与测试（输出一律进文件，不上屏幕）
    unseal
    driver
    bash "$DRV" build >> out/log/驱动输出.txt 2>&1
    ;;
  2) # 编译机：把产物与记录封装成 a1.bin、a2.bin
    k_check
    collect build
    seal_out a1 out/app
    seal_out a2 out/log
    ;;
  3) # 加测机：解开 → 取编译机的产物 → 测试
    unseal
    k_check
    [ -s a1.bin ] || die e9
    dec a1.bin _a.tgz
    mkdir -p out/app
    tar -xzf _a.tgz -C out/app 2>/dev/null || die e9
    rm -f _a.tgz
    driver
    bash "$DRV" test "${2:-x}" >> out/log/驱动输出.txt 2>&1
    ;;
  4) # 加测机：把这台机器的记录封装成 a3-<机器名>.bin
    k_check
    collect "${2:-x}"
    seal_out "a3-${2:-x}" out/log
    ;;
  5) # Windows 编译机：解开 → 编译与启动测试（输出一律进文件，不上屏幕）
    unseal
    driver
    mkdir -p out/wlog
    bash "$DRV" build-win >> out/wlog/驱动输出.txt 2>&1
    ;;
  6) # Windows 编译机：把程序包与记录封装成 a4.bin、a5.bin
    k_check
    seal_out a4 out/win
    seal_out a5 out/wlog
    ;;
  7) # Windows 加测机：解开 → 取编译机的程序包 → 启动测试
    unseal
    driver
    [ -s a4.bin ] || die e12
    dec a4.bin _w.tgz
    mkdir -p out/win out/wlog
    tar -xzf _w.tgz -C out/win 2>/dev/null || die e12
    rm -f _w.tgz
    bash "$DRV" test-win "${2:-x}" >> out/wlog/驱动输出.txt 2>&1
    ;;
  8) # Windows 加测机：把这台机器的记录封装成 a6-<机器名>.bin
    k_check
    seal_out "a6-${2:-x}" out/wlog
    ;;
  *) die e0 ;;
esac
