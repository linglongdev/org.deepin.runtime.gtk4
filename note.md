## 构建时遇到 undefined reference to 的问题

是因为 base 里面安装了 a 包，但是没有安装 a 的 dev 包，在使用 deb-source 安装 deb 依赖时，会跳过 a 包，只安装 a 的 dev 包。
但是 a-dev 包里面的 so 文件一般都是软链接，使用相对路经指向同目录的 a 包里面的 so 文件。

但因为 a 包是在 base 安装的，so 文件在系统目录，a-dev 包是通过 deb-source 安装的，so 文件放在/runtime 下面。

解决办法是 从 base 中删除 a 包或在 base 中安装 a 的 dev 包。

有一个 undefined reference to `dlopen' 比较特殊，libdl qt 会进行两次测试，第一次不加 -libdl 会报错，第二次会加测试正常通过。

## 构建时遇到 include_next 的问题

include_next 的意义是在当前 path 的下一个 path 中查找头文件，所以要先确定当前的 path 列表和报错的文件所在的 path。
解决办法是调整 CPLUS_INCLUDE_PATH，保证要查找的头文件的 path 位于报错的头文件的 path 的后面。
