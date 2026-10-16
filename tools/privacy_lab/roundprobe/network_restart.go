package main

import (
	"errors"
	"fmt"
	"net"
	"os/exec"
	"time"
)

func (n *remoteRole) crashRestart() error {
	started := time.Now()
	old := n.command
	if old == nil || old.Process == nil {
		return errors.New("missing owned process")
	}
	pid := old.Process.Pid
	if e := old.Process.Kill(); e != nil {
		return e
	}
	_ = old.Wait()
	if old.ProcessState == nil {
		return errors.New("old process not reaped")
	}
	_ = n.keepAlive.Close()
	if n.transport != nil {
		n.transport.CloseIdleConnections()
	}
	if n.framed != nil {
		n.framed.Close()
	}
	row := map[string]any{"oldPID": pid, "oldReaped": true, "ready": false}
	n.restarts = append(n.restarts, row)
	cmd := exec.Command(old.Path, old.Args[1:]...)
	cmd.Stderr = n.log
	var e error
	n.command = cmd
	n.keepAlive, e = cmd.StdinPipe()
	if e != nil {
		return e
	}
	stdout, e := cmd.StdoutPipe()
	if e != nil {
		return e
	}
	if e = cmd.Start(); e != nil {
		return e
	}
	ready, scanner, e := readNodeReady(stdout)
	if e != nil || !ready.Ready || fmt.Sprintf("%s-%d", ready.Role, ready.Index) != n.name || ready.WireCodec != n.profile.WireCodec {
		return errors.New("durable role failed to restart")
	}
	host, _, e := net.SplitHostPort(ready.Address)
	if e != nil || net.ParseIP(host) == nil || !net.ParseIP(host).IsLoopback() {
		return errors.New("unexpected resumed endpoint")
	}
	n.address = ready.Address
	if n.framed != nil {
		n.framed = newFramedRPCClient(n.address, n.framed.config, n.framed.dial)
	}
	n.startPrivateReplies(scanner)
	row["newPID"], row["ready"], row["restartMs"] = ready.PID, true, ms(time.Since(started))
	return nil
}
