FROM pg-base

# init db instance
RUN su postgres -c initdb

# start db
#ENTRYPOINT ["sudo", "-u", "postgres", "${bindir}/postgres", "-D", "{pgdatadir}"]
ENTRYPOINT ["/bin/bash"]
