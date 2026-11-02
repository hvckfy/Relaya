window.BENCHMARK_DATA = {
  "lastUpdate": 1793653717621,
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
      },
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
          "id": "96d754fe8f3b8fa6f640165ddeb01c570670cae3",
          "message": "Release: asset guard as a plain if (SC2015)",
          "timestamp": "2026-11-02T23:11:43+03:00",
          "tree_id": "04ff9913b1421f99bc9a3a38696c0a3aea4beb6e",
          "url": "https://github.com/hvckfy/Relaya/commit/96d754fe8f3b8fa6f640165ddeb01c570670cae3"
        },
        "date": 1793653716552,
        "tool": "customSmallerIsBetter",
        "benches": [
          {
            "name": "ssh_config: parse 500 hosts",
            "value": 811.56,
            "unit": "us"
          },
          {
            "name": "fuzzy: rank 500 hosts",
            "value": 256.45,
            "unit": "us"
          },
          {
            "name": "diff: 2000 lines, 40 changed",
            "value": 13518.27,
            "unit": "us"
          },
          {
            "name": "ssh_errors: explain a failed login",
            "value": 12.38,
            "unit": "us"
          },
          {
            "name": "terminal: feed 2000 colored lines",
            "value": 1368.13,
            "unit": "us"
          }
        ]
      }
    ]
  }
}