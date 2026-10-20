// Independent interoperability fixture, using the unmodified Go standard library.
package main

import (
	"bytes"
	"io"
	"log"
	"net"
	"net/http"
	"net/http/fcgi"
	"os"
)

func main() {
	addr := "127.0.0.1:19001"
	if len(os.Args) > 1 {
		addr = os.Args[1]
	}
	l, err := net.Listen("tcp", addr)
	if err != nil {
		log.Fatal(err)
	}
	log.Fatal(fcgi.Serve(l, http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/octet-stream")
		switch r.URL.Path {
		case "/api/echo":
			io.Copy(w, r.Body)
		case "/api/hello":
			w.Header().Set("Content-Type", "application/json")
			io.WriteString(w, `{"message":"hello","query":"`+r.URL.RawQuery+`"}`)
		case "/api/cookies":
			w.Header().Add("Set-Cookie", "a=1")
			w.Header().Add("Set-Cookie", "b=2")
			io.WriteString(w, "cookies")
		case "/api/large":
			w.Write(bytes.Repeat([]byte("x"), 200000))
		default:
			w.WriteHeader(404)
			io.WriteString(w, "Not Found")
		}
	})))
}
