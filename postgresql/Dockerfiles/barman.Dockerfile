FROM pg-base

RUN curl https://dl.2ndquadrant.com/default/release/get/9.6/rpm | sudo bash
RUN yum install -y barman

COPY ./barman_install /root/barman_install
WORKDIR /root/barman_install
RUN python get-pip.py

# official
#RUN pip install -r requirements.txt
# in office (restricted network)
RUN pip install -i http://172.28.247.146:3141/root/prod --trusted-host 172.28.247.146 -r requirements.txt

# PUBLIC_KEY holds the content of host ssh public key, you should assign it when invoking
# the build. E.g. $ docker build --build-arg PUBLIC_KEY="$(cat ~/.ssh/id_rsa.pub)" .
ARG PUBLIC_KEY

# PRIVATE_KEY holds the content of host ssh public key, you should assign it when invoking
# the build. E.g. $ docker build --build-arg PRIVATE_KEY="$(cat ~/.ssh/id_rsa)" .
ARG PRIVATE_KEY

# setup key for "barman"
WORKDIR /tmp
USER barman
RUN cd && mkdir .ssh && echo "$PUBLIC_KEY" >> .ssh/authorized_keys && echo "$PRIVATE_KEY" >> .ssh/id_rsa && chmod 600 .ssh/authorized_keys && chmod 600 .ssh/id_rsa

USER root
WORKDIR /

EXPOSE 22

CMD ["/sbin/sshd", "-D"]
