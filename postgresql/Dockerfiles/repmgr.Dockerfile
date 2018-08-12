FROM pg

# PUBLIC_KEY holds the content of host ssh public key, you should assign it when invoking
# the build. E.g. $ docker build --build-arg PUBLIC_KEY="$(cat ~/.ssh/id_rsa.pub)" .
ARG PUBLIC_KEY

# PRIVATE_KEY holds the content of host ssh public key, you should assign it when invoking
# the build. E.g. $ docker build --build-arg PRIVATE_KEY="$(cat ~/.ssh/id_rsa)" .
ARG PRIVATE_KEY

RUN curl https://dl.2ndquadrant.com/default/release/get/9.6/rpm | sudo bash
RUN yum install -y repmgr96 openssh-server

# ssh is necessary for `switchover`
RUN mkdir /root/.ssh/ && ssh-keygen -A
RUN echo $PUBLIC_KEY >> /root/.ssh/authorized_keys && echo $PRIVATE_KEY >> /root/.ssh/id_rsa && chmod 600 /root/.ssh/authorized_keys && chmod 600 /root/.ssh/id_rsa

EXPOSE 22

# start db
CMD ["/sbin/sshd", "-D"]
