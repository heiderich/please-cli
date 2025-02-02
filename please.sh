#!/usr/bin/env bash

set -uo pipefail

model='gpt-4'
options=("[I] Invoke" "[C] Copy to clipboard" "[A] Abort")
number_of_options=${#options[@]}
keyName="OPENAI_API_KEY"

explain=0
debug_flag=0

initialized=0
selected_option_index=-1

yellow='\e[33m'
cyan='\e[36m'
black='\e[0m'

lightbulb="\xF0\x9F\x92\xA1"
exclamation="\xE2\x9D\x97"

openai_invocation_url=${OPENAI_URL:-"https://api.openai.com/v1"}

check_args() {
  while [[ $# -gt 0 ]]; do
    case "${1}" in
      -e|--explanation)
        explain=1
        shift
        ;;
      -l|--legacy)
        model="gpt-3.5-turbo"
        shift
        ;;
      --debug)
        debug_flag=1
        shift
        ;;
      -a|--api-key)
        store_api_key
        exit 0
        ;;
      -v|--version)
        display_version
        exit 0
        ;;
      -h|--help)
        display_help
        exit 0
        ;;
      *)
        break
        ;;
    esac
  done

  # Save remaining arguments to a string
  commandDescription="$*"
}

function store_api_key() {
    echo "Do you want the script to store an API key in the local keychain? (y/n)"
    read -r answer

    if [ "$answer" != "y" ]; then
        echo "This script will need an API Key to run. Exiting..."
        exit 1
    fi

    echo "The script needs to create or copy the API key. Press Enter to continue..."
    read -rs

    apiKeyUrl="https://platform.openai.com/account/api-keys"
    echo "Opening ${apiKeyUrl} in your browser..."
    open "${apiKeyUrl}" || xdg-open "${apiKeyUrl}"

    while true; do
        echo "Please enter your API key: [Press Ctrl+C to exit]"
        read -rs apiKey

        if [ -z "$apiKey" ]; then
            echo "API key cannot be empty. Please try again."
        else
            if [[ "$OSTYPE" == "darwin"* ]]; then
                security add-generic-password -a "${USER}" -s "${keyName}" -w "${apiKey}" -U
                OPENAI_API_KEY=$(security find-generic-password -a "${USER}" -s "${keyName}" -w)
            else
                echo -e "${apiKey}" | secret-tool store --label="${keyName}" username "${USER}" key_name "${keyName}"
                OPENAI_API_KEY=$(secret-tool lookup username "${USER}" key_name "${keyName}")
            fi
            echo "API key stored successfully and set as a global variable."
            break
        fi
    done
}

display_version() {
  echo "Please vVERSION_NUMBER"
}

display_help() {
  echo "Please - a simple script to translate your thoughts into command line commands using GPT"
  echo "Usage: $0 [options] [input]"
  echo
  echo "Options:"
  echo "  -e, --explanation    Explain the command to the user"
  echo "  -l, --legacy         Use GPT 3.5 (in case you do not have GPT4 API access)"
  echo "      --debug          Show debugging output"
  echo "  -a, --api-key        Store your API key in the local keychain"
  echo "  -v, --version        Display version information and exit"
  echo "  -h, --help           Display this help message and exit"
  echo
  echo "Input:"
  echo "  The remaining arguments are used as input to be turned into a CLI command."
  echo
  echo "OpenAI API Key:"
  echo "  The API key needs to be set as OPENAI_API_KEY environment variable or keychain entry. "
}


debug() {
    if [ "$debug_flag" = 1 ]; then
        echo "DEBUG: $1" >&2
    fi
}

check_key() {
  if [ -z "${OPENAI_API_KEY+x}" ]; then
    debug "OPENAI_API_KEY environment variable not set, trying to find it in keychain"
    get_key_from_keychain
  fi
}


get_key_from_keychain() {
  case "$(uname)" in
    Darwin*) # macOS
      key=$(security find-generic-password -a "${USER}" -s "${keyName}" -w)
      exitStatus=$?
      ;;
    Linux*)
      if ! command -v secret-tool &> /dev/null; then
        debug "OPENAI_API_KEY not set and secret-tool not installed. Install it with 'sudo apt install libsecret-tools'."
        exitStatus=1
      else
        key=$(secret-tool lookup username "${USER}" key_name "${keyName}")
        exitStatus=$?
      fi
      ;;
    *)
      debug "OPENAI_API_KEY not set and no supported keychain available."
      exitStatus=1
      ;;
  esac

  if [ "${exitStatus}" -ne 0 ]; then
    echo "OPENAI_API_KEY not set and unable to find it in keychain. See the README on how to persist your key."
    echo "You can get an API at https://beta.openai.com/"
    echo "Please enter your OpenAI API key now to use it this time only, or rerun 'please -a' to store it in the keychain."
    echo "Your API Key:"
    read -r key
  fi

  if [ -z "${key}" ]; then
    echo "No API key provided. Exiting."
    exit 1
  fi
  OPENAI_API_KEY="${key}"
}

get_command() {
  role="You translate the input given into Linux command. You may not use natural language, but only a Linux commands as answer.
  Do not use markdown. Do not quote the whole output. If you do not know the answer, answer with echo 'I do not know'."

  payload=$(printf %s "$commandDescription" | jq --slurp --raw-input --compact-output '{
    model: "'"$model"'",
    messages: [{ role: "system", content: "'"$role"'" }, { role: "user", content: . }]
  }')

  debug "Sending request to OpenAI API: ${payload}"

  perform_openai_request
  command="${message}"
}

explain_command() {
  prompt="Explain what the command ${command} does. Don't be too verbose."

  payload=$(printf %s "$prompt" | jq --slurp --raw-input --compact-output '{
    max_tokens: 100,
    model: "'"$model"'",
    messages: [{ role: "user", content: . }]
  }')

  perform_openai_request
  explanation="${message}"
}

perform_openai_request() {
  IFS=$'\n' read -r -d '' -a result < <(curl "${openai_invocation_url}/chat/completions" \
       -s -w "\n%{http_code}" \
       -H "Content-Type: application/json" \
       -H "Authorization: Bearer ${OPENAI_API_KEY}" \
       -d "${payload}" \
       --silent)
  debug "Response:\n${result[*]}"
  length="${#result[@]}"
  httpStatus="${result[$((length-1))]}"

  length="${#result[@]}"
  response_array=("${result[*]:0:$((length-1))}")
  response="${response_array[*]}"

  if [ "${httpStatus}" -ne 200 ]; then
    echo "Error: Received HTTP status ${httpStatus}"
    echo "${response}" | jq .error.message --raw-output
    exit 1
  else
    message=$(echo "${response}" | jq '.choices[0].message.content' --raw-output)
  fi
}

print_option() {
  # shellcheck disable=SC2059
  printf "${lightbulb} ${cyan}Command:${black}\n"
  echo "  ${command}"
  if [ "${explain}" -eq 1 ]; then
    echo ""
    echo "${explanation}"
  fi
  echo ""
  # shellcheck disable=SC2059
  printf "${exclamation} ${yellow}What should I do? ${cyan}[use arrow keys to navigate]${black}\n"
}

choose_action() {
  while true; do
    display_menu

    read -rsn1 input
    # Check for arrow keys and 'Enter'
    case "$input" in
      $'\x1b')
        read -rsn1 tmp
        if [[ "$tmp" == "[" ]]; then
          read -rsn1 tmp
          case "$tmp" in
            "D") # Right arrow
              selected_option_index=$(( (selected_option_index - 1 + number_of_options) % number_of_options ))
              ;;
            "C") # Left arrow
              selected_option_index=$(( (selected_option_index + 1) % number_of_options ))
              ;;
          esac
        fi
        ;;
      i)
        selected_option_index=0
        display_menu
        break
        ;;

      c)
        selected_option_index=1
        display_menu
        break
        ;;
      a)
        selected_option_index=2
        display_menu
        break
        ;;

      "") # 'Enter' key
        if [ "$selected_option_index" -ne -1 ]; then
          break
        fi
        ;;
    esac
  done
}

display_menu() {
  if [ $initialized -eq 1 ]; then
    # Go up 1 line
    printf "\033[%dA" "1"
  else
    initialized=1
  fi

  index=0
  for option in "${options[@]}"; do
    (( index == selected_option_index )) && marker="${cyan}>${black}" || marker=" "
    # shellcheck disable=SC2059
    printf "$marker $option "
    (( ++index ))
  done
  printf "\n"
}

act_on_action() {
  if [ "$selected_option_index" -eq 0 ]; then
    echo "Executing ..."
    echo ""
    execute_command
  elif [ "$selected_option_index" -eq 1 ]; then
    echo "Copying to clipboard ..."
    copy_to_clipboard
  else
    exit 0
  fi
}

execute_command() {
    eval "${command}"
}

copy_to_clipboard() {
  case "$(uname)" in
    Darwin*) # macOS
      echo -n "${command}" | pbcopy
      ;;
    Linux*)
      if [ "$XDG_SESSION_TYPE" == "wayland" ]; then
        echo -n "${command}" | wl-copy --primary
      else
        echo -n "${command}" | xclip -selection clipboard
      fi
      ;;
    *)
      echo "Unsupported operating system"
      exit 1
      ;;
  esac
}

if [ $# -eq 0 ]; then
  input=("-h")
else
  input=("$@")
fi

check_args "${input[@]}"
check_key

get_command
if [ "${explain}" -eq 1 ]; then
  explain_command
fi

print_option
choose_action
act_on_action
