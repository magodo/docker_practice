FROM centos:6.8

# PUBLIC_KEY holds the content of host ssh public key, you should assign it when invoking
# the build. E.g. $ docker build --build-arg PUBLIC_KEY="$(cat ~/.ssh/id_rsa.pub)" .
ARG PUBLIC_KEY

RUN yum update -y && yum install -y \
    openssh-server \
    python-simplejson

# sshd needs this directory
RUN mkdir /var/run/sshd

# remember the public key of the host
RUN mkdir /root/.ssh/
RUN echo $PUBLIC_KEY >> /root/.ssh/authorized_keys

# ensure the host keys are generated
RUN ["/sbin/service", "sshd", "start"]
RUN ["/sbin/service", "sshd", "stop"]

EXPOSE 22 80 3306

CMD ["/usr/sbin/sshd", "-D"]
