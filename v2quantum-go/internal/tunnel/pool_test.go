package tunnel

import (
	"context"
	"testing"
	"time"
)

func TestWaitPickWakesWhenStreamCapacityReturns(t *testing.T) {
	p := newSessionPool()
	s := &session{maxStreams: 1, closed: make(chan struct{})}
	s.active.Store(1)
	p.add(s)

	go func() {
		time.Sleep(100 * time.Millisecond)
		s.active.Store(0)
	}()

	ctx, cancel := context.WithTimeout(context.Background(), time.Second)
	defer cancel()
	got, err := p.waitPick(ctx)
	if err != nil {
		t.Fatal(err)
	}
	if got != s {
		t.Fatal("waitPick returned the wrong session")
	}
}
