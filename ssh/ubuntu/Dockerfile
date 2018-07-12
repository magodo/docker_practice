FROM ubuntu

# PUBLIC_KEY holds the content of host ssh public key, you should assign it when invoking
# the build. E.g. $ docker build --build-arg PUBLIC_KEY="$(cat ~/.ssh/id_rsa.pub)" .
ARG PUBLIC_KEY

RUN apt-get update && apt-get install -y \
    openssh-server \
    python-simplejson

# sshd needs this directory
RUN mkdir /var/run/sshd

# remember the public key of the host
RUN mkdir /root/.ssh/
RUN echo $PUBLIC_KEY >> /root/.ssh/authorized_keys

EXPOSE 22

CMD ["/usr/sbin/sshd", "-D"]
