FROM centos

RUN yum install -y https://download.postgresql.org/pub/repos/yum/9.6/redhat/rhel-6-x86_64/pgdg-centos96-9.6-3.noarch.rpm
RUN yum install -y vim iproute postgresql96 postgresql96-server sudo
RUN yum install -y telnet

USER postgres
ARG pgversion=9.6
ENV PGDATA /var/lib/pgsql/${pgversion}/data
ENV PATH /usr/pgsql-${pgversion}/bin:$PATH

# init db instance
RUN initdb

# port
EXPOSE 5432

# copy scripts into container
COPY scripts /opt/scripts

# start db
#ENTRYPOINT ["sudo", "-u", "postgres", "${bindir}/postgres", "-D", "{pgdatadir}"]
ENTRYPOINT ["/bin/bash"]
