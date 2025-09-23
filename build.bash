#!/bin/bash
# 安装依赖
echo "- 开始构建Runtime"
bash ./install_dep linglong/sources "$PREFIX"
# 删除字体文件
rm -rf $PREFIX/share/fonts
