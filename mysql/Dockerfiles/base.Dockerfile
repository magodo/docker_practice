FROM ubuntu

RUN apt-get update && apt-get install -y mysql-server vim iproute2 iputils-ping telnet sudo uuid rsync bc

USER root

EXPOSE 3306

CMD /bin/bash
