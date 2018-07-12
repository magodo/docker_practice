基础镜像作为stage给后续使用：

1. pg-base:

    描述：在`centos@6.8`基础上安装pg9.6并初始化数据库，配置文件允许远程主机连接，启动数据库。

    编译命令：`docker build --rm -t pg-base -f Dockerfile .`
