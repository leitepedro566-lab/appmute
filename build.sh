#!/bin/bash
# 运行前确保执行: chmod +x build.sh

echo ">>> 正在清理历史残留文件..."
make clean

echo ">>> 正在编译 经典有根越狱版 (Rootful) 架构..."
make package

echo ">>> 正在编译 现代主流无根版 (Rootless) 架构..."
make package THEOS_PACKAGE_SCHEME=rootless

echo ">>> 正在编译 隐藏越狱无根版 (Roothide) 架构..."
make package THEOS_PACKAGE_SCHEME=roothide

echo ">>> 🎉 编译结束！所有多架构越狱包均已在 packages/ 下生成完成。"
