FROM pg

RUN curl https://dl.2ndquadrant.com/default/release/get/9.6/rpm | sudo bash
RUN yum install -y repmgr96 

# start db
CMD ["/sbin/sshd", "-D"]
