FROM centos

RUN yum install -y https://download.postgresql.org/pub/repos/yum/9.6/redhat/rhel-6-x86_64/pgdg-centos96-9.6-3.noarch.rpm
RUN yum install -y vim iproute postgresql96 postgresql96-server sudo uuid rsync openssh-server openssh-clients telnet bc

ARG pgversion=9.6
ENV PGDATA /var/lib/pgsql/${pgversion}/data
ENV PATH /usr/pgsql-${pgversion}/bin:$PATH

################################################
# setup for ssh
################################################

# PUBLIC_KEY holds the content of host ssh public key, you should assign it when invoking
# the build. E.g. $ docker build --build-arg PUBLIC_KEY="$(cat ~/.ssh/id_rsa.pub)" .
ARG PUBLIC_KEY

# PRIVATE_KEY holds the content of host ssh public key, you should assign it when invoking
# the build. E.g. $ docker build --build-arg PRIVATE_KEY="$(cat ~/.ssh/id_rsa)" .
ARG PRIVATE_KEY

# setup ssh for "repmgr"
RUN ssh-keygen -A
USER postgres
RUN cd && mkdir .ssh && echo "$PUBLIC_KEY" >> .ssh/authorized_keys && echo "$PRIVATE_KEY" >> .ssh/id_rsa && chmod 600 .ssh/authorized_keys && chmod 600 .ssh/id_rsa

USER root

# port
EXPOSE 5432 22

CMD ["/sbin/sshd", "-D"]
