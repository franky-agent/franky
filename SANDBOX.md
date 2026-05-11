# sbx

```
sbx create --template containifyci/claude-code shell .
sbx run shell-franky
sbx ports shell-franky --publish 8787:8787
```

# cerebras
sbx secret set-custom -g --host api.cerebras.ai --env CEREBRAS_API_KEY --value ${CEREBRAS_API_KEY}

# cloudflare
sbx secret set-custom -g --host api.cloudflare.com --env CF_API_TOKEN --value ${CF_API_TOKEN}
sbx secret set-custom -g --host api.cloudflare.com --env CF_ACCOUNT_ID --value ${CF_ACCOUNT_ID}$

# mistral
teller run --reset --shell -- sh -c 'sbx secret set-custom -g --host api.mistral.ai --env MISTRAL_API_KEY --value ${MISTRAL_API_KEY}'

# ollama
teller run --reset --shell -- sh -c 'sbx secret set-custom -g --host ollama.com --env OLLAMA_API_KEY --value ${OLLAMA_API_KEY}'

# openrouter
sbx secret set-custom -g --host openrouter.ai --env OPENROUTER_KEY --value ${OPENROUTER_KEY}

# gemini
teller run --reset --shell -- sh -c 'echo "$GEMINI_API_KEY" | sbx secret set -g google'
teller run --reset --shell -- sh -c 'sbx secret set-custom -g --host googleapis.com --env OLLAMA_API_KEY --value ${GEMINI_API_KEY}'

# openai
teller run --reset --shell -- sh -c 'echo "$OPENAI_API_KEY" | sbx secret set -g openai'
teller run --reset --shell -- sh -c 'sbx secret set-custom -g --host openai.com --env OPENAI_API_KEY --value ${OPENAI_API_KEY}'



We can also wrap this up with teller so that we can have a .teller.yaml file
that fetch the secrets and setup the sbx secret without the secrets ever being stored on disk or in environment variables.