FROM pg-base

# init db instance
RUN su postgres -c initdb

CMD ["/sbin/sshd", "-D"]
