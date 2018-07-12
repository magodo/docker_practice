FROM ubuntu

RUN apt-get update && apt-get install -y mysql-server vim iproute2 iputils-ping telnet
RUN service mysql start

EXPOSE 3306

CMD ["/bin/bash"]
