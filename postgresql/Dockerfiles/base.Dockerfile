FROM centos

RUN yum install -y https://download.postgresql.org/pub/repos/yum/9.6/redhat/rhel-6-x86_64/pgdg-centos96-9.6-3.noarch.rpm
RUN yum install -y vim iproute postgresql96 postgresql96-server sudo uuid rsync
RUN yum install -y telnet

ARG pgversion=9.6
ENV PGDATA /var/lib/pgsql/${pgversion}/data
ENV PATH /usr/pgsql-${pgversion}/bin:$PATH

# port
EXPOSE 5432

# start db
CMD ["/bin/bash"]
