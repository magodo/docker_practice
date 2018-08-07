镜像
===

基础镜像作为stage给后续使用：

1. pg-base:

    描述：在`centos@6.8`基础上安装pg9.6以及一些开发包，但是并不初始化DB

    编译命令：`docker build --rm -t pg-base -f Dockerfiles/base.Dockerfile .`

2. pg:

    描述：在`pg-base`基础上初始化数据库。

    编译命令：`docker build --rm -t pg -f Dockerfiles/init.Dockerfile .`

实践
===

PIT 恢复
---

首先，创建一个docker volume用来存放归档WAL文件：

    $ docker volume create my-vol

基于`pg`image启动一个容器（将scripts `bind mount` 上去，将刚创建的volume以`volume`的形式挂载上去）：

    $ # 在项目根目录执行（因为bind-mount要指定路径）
    $ docker run --rm -Pdit --name test --mount 'type=volume,src=my-vol,dst=/mnt/backup' --mount "type=bind,src=$(pwd)/scripts,dst=/opt/scripts" pg
    $ docker exec -it test bash

进入这个容器并执行 */opt/scripts/pitr/main.py*:

    [root@efc0e941654c /]# cd /opt/scripts/pitr/
    [root@efc0e941654c pitr]# ./main.sh /mnt/backup/ start                                                                          
    server starting                                                                                                                 
    [root@efc0e941654c pitr]# < 2018-08-05 14:07:35.056 UTC > LOG:  could not bind IPv6 socket: Cannot assign requested address     
    < 2018-08-05 14:07:35.056 UTC > HINT:  Is another postmaster already running on port 5432? If not, wait a few seconds and retry.
    < 2018-08-05 14:07:35.079 UTC > LOG:  redirecting log output to logging collector process                                       
    < 2018-08-05 14:07:35.079 UTC > HINT:  Future log output will appear in directory "pg_log".                                     

以上指令会配置备份目录，配置pg配置文件，然后启动服务。

然后，可以在db中随意执行一些指令：

    [root@efc0e941654c pitr]# su postgres -c 'psql'   
    psql (9.6.9)                                      
    Type "help" for help.                             
  
    postgres=# create table foo(t timestamp);         
    CREATE TABLE                                      
    postgres=# insert into foo values(LOCALTIMESTAMP);
    INSERT 0 1                                        


接着，进行basebackup：

    [root@efc0e941654c pitr]# ./main.sh /mnt/backup/ basebackup  
    9eee9ee2-98b9-11e8-8106-0242aa110002

这会返回一个备份ID，该ID用于后续的恢复。

至此，我们已经创建basebackup，并且配置了continuous archive。运行中PG会不断的将新生成的WAL归档到我们指定的目录(*/mnt/backup/archive*)。

接下来，起另外一个容器做从备份PIT恢复:

    $ # 在项目根目录执行（因为bind-mount要指定路径）
    $ docker run --rm -Pdit --name test_rec --mount 'type=volume,src=my-vol,dst=/mnt/backup' --mount "type=bind,src=$(pwd)/scripts,dst=/opt/scripts" pg
    $ docker exec -it test_rec bash

进入这个容器并执行 */opt/scripts/pitr/main.py*:

    [root@eb6f6a9c8191 pitr]# ./main.sh /mnt/backup/ recover 9eee9ee2-98b9-11e8-8106-0242aa110002
    pg_ctl: no server running                                                                                                       
    server starting                                                                                                                 
    [root@eb6f6a9c8191 pitr]# < 2018-08-05 14:15:24.779 UTC > LOG:  could not bind IPv6 socket: Cannot assign requested address     
    < 2018-08-05 14:15:24.779 UTC > HINT:  Is another postmaster already running on port 5432? If not, wait a few seconds and retry.
    < 2018-08-05 14:15:24.799 UTC > LOG:  redirecting log output to logging collector process                                       
    < 2018-08-05 14:15:24.799 UTC > HINT:  Future log output will appear in directory "pg_log".                                     

验证内容：

	[root@eb6f6a9c8191 pitr]# su postgres -c "psql -c 'select * from foo;'"
				 t                                                         
	----------------------------                                           
	 2018-08-07 03:38:18.064691                                            
	(1 row)                                                                

结束后，停止/删除两个容器，并且删除volume：

    $ docker stop test test_rec
    $ docker volume rm my-vol
