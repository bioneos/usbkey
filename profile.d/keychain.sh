#! /bin/bash 
if [[ ! -z $SSH_CLIENT || ! -z $SSH_CONNECTION ]]; then
  echo "Remote connection detected (SSH)"
  echo "Welcome to `hostname`"
  echo
else
  eval `keychain --quiet --eval`
fi

