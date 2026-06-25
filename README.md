# Docker Images for [Flutter](https://flutter.dev/)

```bash
docker run --rm -it -v ${PWD}:/build --workdir /build ghcr.io/davidmartos96/flutter:stable flutter test
```

The example above simply mount current working directory and runs `flutter test`

