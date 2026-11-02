window.BENCHMARK_DATA = {
  "lastUpdate": 1793646057596,
  "repoUrl": "https://github.com/hvckfy/Relaya",
  "entries": {
    "Relaya core": [
      {
        "commit": {
          "author": {
            "email": "ruslan.miftakhov@dizzaract.com",
            "name": "Ruslan",
            "username": "ruslanmiftakhov-tech"
          },
          "committer": {
            "email": "ruslan.miftakhov@dizzaract.com",
            "name": "Ruslan",
            "username": "ruslanmiftakhov-tech"
          },
          "distinct": false,
          "id": "0174ab7e0f1adc8ada705f68e5f76803d1744898",
          "message": "CI: build-core runs the Windows script in pwsh, not Git Bash",
          "timestamp": "2026-11-02T20:04:09+03:00",
          "tree_id": "377c691ce70651065f70a637c6237a7b949df6ac",
          "url": "https://github.com/hvckfy/Relaya/commit/0174ab7e0f1adc8ada705f68e5f76803d1744898"
        },
        "date": 1793646055799,
        "tool": "customSmallerIsBetter",
        "benches": [
          {
            "name": "ssh_config: parse 500 hosts",
            "value": 772.85,
            "unit": "us"
          },
          {
            "name": "fuzzy: rank 500 hosts",
            "value": 188.35,
            "unit": "us"
          },
          {
            "name": "diff: 2000 lines, 40 changed",
            "value": 14145.99,
            "unit": "us"
          },
          {
            "name": "ssh_errors: explain a failed login",
            "value": 11.07,
            "unit": "us"
          },
          {
            "name": "terminal: feed 2000 colored lines",
            "value": 1342.9,
            "unit": "us"
          }
        ]
      }
    ]
  }
}