# proxy-port.sh - sourced by the suites that boot the OS against a mock
# llm-proxy.py. The OS always talks to the slirp host alias 10.0.2.2:4080.
#
#   LLM_PROXY_PORT=4080 (default)  proxy on host :4080, plain slirp
#   LLM_PROXY_PORT=<n>             proxy on host :<n>
#   LLM_PROXY_PORT=auto            a free random host port ('make test-all'
#                                  sets this, so parallel gates and a stray
#                                  proxy on :4080 never collide)
#
# For a port other than 4080, slirp's host alias moves to 10.0.2.4 (it
# refuses a guestfwd on its own alias; 10.0.2.3 is DNS) and 10.0.2.2:4080
# is forwarded to 127.0.0.1:$PPORT. Use:  --port "$PPORT"  for the proxy and
# -netdev "user,id=n0$PFWD"  (quoted: the forward runs nc) for QEMU.
PPORT="${LLM_PROXY_PORT:-4080}"
if [ "$PPORT" = auto ]; then
  PPORT="$(python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1", 0)); print(s.getsockname()[1])')"
fi
PFWD=""
[ "$PPORT" != 4080 ] && PFWD=",host=10.0.2.4,guestfwd=tcp:10.0.2.2:4080-cmd:nc 127.0.0.1 $PPORT"
