module farvahartrends.local/privacy-roundprobe

go 1.27.2

require (
	farvahartrends.local/privacy-lab/setupprobe v0.0.0
	farvahartrends.local/privacy-lab/verdictprobe v0.0.0
	github.com/fxamacker/cbor/v2 v2.9.1
	go.etcd.io/bbolt v1.5.0
	golang.org/x/crypto v0.48.0
	golang.org/x/sys v0.45.0
)

require (
	github.com/x448/float16 v0.8.4 // indirect
	go.dedis.ch/fixbuf v1.0.3 // indirect
	go.dedis.ch/kyber/v4 v4.0.2 // indirect
)

replace farvahartrends.local/privacy-lab/setupprobe => ../setupprobe

replace farvahartrends.local/privacy-lab/verdictprobe => ../verdictprobe
