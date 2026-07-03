.PHONY: default

default:
	rm -fv lambda-handler.zip bootstrap
	GOOS=linux GOARCH=arm64 go build -trimpath -o bootstrap main.go
	TZ=UTC touch -t 202001010000.00 bootstrap
	zip -X -9 lambda-handler.zip bootstrap
	rm -fv bootstrap
