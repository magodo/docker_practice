镜像
===

基础镜像作为stage给后续使用：

1. pg-base:

    描述：在`centos@6.8`基础上安装pg9.6以及一些开发包，但是并不初始化DB

    编译命令：`docker build --rm -t pg-base -f base.Dockerfile .`

2. pg:

    描述：在`pg-base`基础上初始化数据库。

    编译命令：`docker build --rm -t pg -f init.Dockerfile .`

3. repmgr

    描述：在`pg`基础上，加入了repmgr包以及它的`switchover`功能所依赖的ssh

    编译命令：`docker build --rm -t repmgr -f repmgr.Dockerfile --build-arg PUBLIC_KEY="$(cat ~/.ssh/id_rsa.pub)" --build-arg PRIVATE_KEY="$(cat ~/.ssh/id_rsa)" .`

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

Failover && Failback
---

首先，进入*Dockerfiles/ha*，该目录下的内容有：

1. *scripts*目录的link，用于启动service的时候做`bind mount`
2. *.env*文件，指向*scripts/config.sh*，用于启动service的时候读取环境变量
3. *docker-compose.yml*，用于启动两个service：primary和standby，用来跑DB服务

这里的*docker-compose.yml*还会创建两个网络，一个是用于primary和standby内部通信（用于复制，rewind, basebackup等操作）；一个是用于接收外界pg客户端请求，这个网络只提供一个特定的IP：`VIP`，它会在failover的时候绑定到新的primary上。

在*Dockerfiles/ha*目录下执行以下指令启动两个服务：

    💤  ha [master] ⚡  cd Dockerfiles/ha
    💤  ha [master] ⚡  docker-compose up -d

在host环境下通过*scripts/ha/witness_main.sh*来进行各种操作。

    💤  ha [master] ⚡  cd scripts/ha

首先，配置主从并且启动它们：

    💤  ha [master] ⚡  ./witness_main.sh start -h
    Usage: start [option] [primary_container] [standby_container]

    Options:
        -h, --help
        -i, --init              setup primary and standby before start

    💤  ha [master] ⚡  ./witness_main.sh start -i ha_p1_1 ha_p2_1
    waiting for server to start....< 2018-08-10 09:47:05.453 UTC > LOG:  redirecting log output to logging collector process
    < 2018-08-10 09:47:05.453 UTC > HINT:  Future log output will appear in directory "pg_log".
     done
    server started
    DO
    DO
    DO
    waiting for server to shut down.... done
    server stopped

（这里的输出不用理会哈...）

然后，可以另开一个窗口模拟用户访问DB：

    💤  colors [master] ⚡  psql -h 172.255.255.254 -U postgres
    Password for user postgres:
    psql (10.4, server 9.6.9)
    Type "help" for help.

    postgres=# create table a(i int);
    CREATE TABLE

（postgres的密码是: 123）

接下来，模拟**failover**操作：

    💤  ha [master] ⚡  ./witness_main.sh failover -h
    Usage: failover [option] [primary_container] [standby_container]

    Description: configure network so that VIP is bound to standby, then promote standby as primary.

    Options:
        -h, --help
        -p, --project           docker-compose project

    💤  ha [master] ⚡  ./witness_main.sh failover -p ha ha_p1_1 ha_p2_1
    server promoting
    DO

此时，`ha_p2_1`获得了VIP，并且进入**primary mode**，向外提供服务。

容灾之后，当`ha_p1_1`重新恢复服务之后，需要对它进行**failback**操作，以使之成为`ha_p2_1`的standby：

    💤  ha [master] ⚡  ./witness_main.sh failback -h
    Usage: failback [option] [failbackup_container]

    Options:
        -h, --help

    💤  ha [master] ⚡  ./witness_main.sh failback ha_p1_1
    waiting for server to shut down.... done
    server stopped
    servers diverged at WAL position 0/3015FE8 on timeline 1
    rewinding from last common checkpoint at 0/2000060 on timeline 1
    Done!

最后，在完成实践后关闭容器和相关的资源（网络，存储）：

    💤  ha [master] ⚡  cd Dockerfiles/ha
    💤  ha [master] ⚡  docker-compose down
    Stopping ha_p2_1 ... done        
    Stopping ha_p1_1 ... done        
    Removing ha_p2_1 ... done        
    Removing ha_p1_1 ... done        
    Removing network ha_internal_net 
    Removing network ha_external_net 
