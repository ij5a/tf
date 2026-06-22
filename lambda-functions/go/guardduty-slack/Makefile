build:
	GOOS=linux GOARCH=arm64 go build -tags lambda.norpc -o bootstrap .
	zip -j lambda-handler.zip bootstrap
