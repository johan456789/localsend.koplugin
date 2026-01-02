package session

import (
	"log/slog"
	"sync"
	"time"

	"localsend-cli/internal/localsend/constants"
	"localsend-cli/internal/models"
	"github.com/google/uuid"
)

type RecvSessManager struct {
	sessions *sync.Map
	done     chan struct{}
}

func NewRecvSessManager() *RecvSessManager {
	return &RecvSessManager{
		sessions: &sync.Map{},
		done:     make(chan struct{}),
	}
}

func (rsm *RecvSessManager) Start() {
	go rsm.vacuumTask()
}

func (rsm *RecvSessManager) Stop() {
	close(rsm.done)
}

func (rsm *RecvSessManager) vacuumTask() {
	ticker := time.NewTicker(5 * time.Second)
	defer ticker.Stop()

	for {
		select {
		case <-rsm.done:
			return
		case <-ticker.C:
			rsm.sessions.Range(func(key, value any) bool {
				sessionId, ok := key.(string)
				if !ok {
					return true // skip invalid entry
				}
				session, ok := value.(*RecvSession)
				if !ok {
					return true // skip invalid entry
				}

				if session.Stopped() {
					slog.Info("Cleanup stopped session", "session", sessionId)
					rsm.sessions.Delete(sessionId)
				}

				return true
			})
		}
	}
}

func (rsm *RecvSessManager) GeneratePreUploadResp(sessionId string) (models.PreUploadResp, error) {
	sess, err := rsm.GetSession(sessionId)
	if err != nil {
		return models.PreUploadResp{}, err
	}

	var resp models.PreUploadResp
	resp.Tokens = sess.FileTokens()
	resp.SessionId = sessionId

	return resp, nil
}

func (rsm *RecvSessManager) NewSession(reqFiles models.FileMetas, clientIP string) (string, error) {
	sessionId := uuid.NewString()
	session, err := NewRecvSession(sessionId, clientIP)
	if err != nil {
		return "", err
	}

	// accept every files the client claimed
	for fileId, fileMeta := range reqFiles {
		err = session.AcceptFile(fileId, fileMeta)
		if err != nil {
			return "", err
		}
	}

	// store and start session
	rsm.sessions.Store(sessionId, session)
	session.Start()

	return sessionId, nil
}

func (rsm *RecvSessManager) KillSession(sessionId string) {
	v, exist := rsm.sessions.LoadAndDelete(sessionId)
	if !exist {
		return
	}
	sess, ok := v.(*RecvSession)
	if !ok {
		return
	}
	sess.End()
}

func (rsm *RecvSessManager) GetSession(sessionId string) (*RecvSession, error) {
	v, exist := rsm.sessions.Load(sessionId)
	if !exist {
		return nil, constants.ErrNotFound
	}
	session, ok := v.(*RecvSession)
	if !ok {
		return nil, constants.ErrNotFound
	}

	return session, nil
}

// HasActiveSessions returns true if there are any active (non-stopped) sessions
// per protocol spec Section 4.1: return 409 when "Blocked by another session"
func (rsm *RecvSessManager) HasActiveSessions() bool {
	hasActive := false
	rsm.sessions.Range(func(key, value any) bool {
		session, ok := value.(*RecvSession)
		if !ok {
			return true // skip invalid entry
		}
		if !session.Stopped() {
			hasActive = true
			return false // stop iteration
		}
		return true
	})
	return hasActive
}
