module farvahartrends.local/privacy-lab/sphinxprobe

go 1.26.2

require (
	github.com/katzenpost/hpqc v0.0.84-0.20260603082753-be60338910ec
	github.com/katzenpost/katzenpost v0.0.90
	golang.org/x/sys v0.44.0
)

require (
	filippo.io/mlkem768 v0.0.0-20260214141301-2e7bebc7d88d // indirect
	github.com/BurntSushi/toml v1.6.0 // indirect
	github.com/fxamacker/cbor/v2 v2.9.1 // indirect
	github.com/katzenpost/chacha20 v0.0.1 // indirect
	github.com/x448/float16 v0.8.4 // indirect
	gitlab.com/yawning/aez.git v0.0.0-20211027044916-e49e68abd344 // indirect
	gitlab.com/yawning/bsaes.git v0.0.0-20190805113838-0a714cd429ec // indirect
	golang.org/x/crypto v0.51.0 // indirect
)

replace github.com/katzenpost/katzenpost => ../../../.tooling/privacy-research/katzenpost

replace github.com/katzenpost/hpqc => ../../../.tooling/privacy-research/hpqc-portable
