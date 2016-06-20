defmodule SMPPSend do

  require Logger
  use Dye

  @switches [
    help: :boolean,

    bind_mode: :string,
    host: :string,
    port: :integer,
    system_id: :string,
    password: :string,
    system_type: :string,
    interface_version: :integer,
    addr_ton: :integer,
    addr_npi: :integer,
    address_range: :string,

    submit_sm: :boolean,
    service_type: :string,
    source_addr_ton: :integer,
    source_addr_npi: :integer,
    source_addr: :string,
    dest_addr_ton: :integer,
    dest_addr_npi: :integer,
    destination_addr: :string,
    esm_class: :integer,
    protocol_id: :integer,
    priority_flag: :integer,
    schedule_delivery_time: :string,
    validity_period: :string,
    registered_delivery: :integer,
    replace_if_present_flag: :integer,
    data_coding: :integer,
    sm_default_msg_id: :integer,
    short_message: :string,

    split_max_bytes: :integer,

    udh: :boolean,
    udh_ref: :integer,
    udh_total_parts: :integer,
    udh_part_num: :integer,

    ucs2: :boolean,

    wait_dlrs: :integer,
    wait: :boolean
  ]

  @defaults [
    bind_mode: "tx",
    esm_class: 0,
    short_message: "",
    submit_sm: false,

    auto_split: false,

    udh: false,
    udh_ref: 0,
    udh_total_parts: 1,
    udh_part_num: 1,

    ucs2: false,

    wait: false
  ]

  @required [
    :bind_mode,
    :host,
    :port,
    :system_id,
    :password,
    :submit_sm
  ]

  def main(args) do
    args
    |> parse
    |> convert_tlvs
    |> validate_unknown
    |> set_defaults
    |> show_help
    |> validate_missing
    |> convert_to_ucs2
    |> start_servers
    |> bind
    |> send_messages
    |> wait_dlrs
    |> wait
  end

  defp parse(args) do
    {parsed, remaining, invalid} = OptionParser.parse(args, switches: @switches)

    if length(invalid) > 0 do
      error!(1, "Invalid options: #{format_keys(invalid)}")
    end
    if length(remaining) > 0 do
      error!(1, "Redundant command line arguments: #{format_keys(remaining)}")
    end

    parsed
  end

  defp format_keys(keys) when not is_list(keys), do: format_keys([keys])
  defp format_keys(keys) do
    keys |> Enum.map(&original_key/1) |> Enum.map(&inspect/1) |> Enum.join(", ")
  end

  defp original_key({key, _}), do: to_string(key)
  defp original_key(key) when is_binary(key), do: key
  defp original_key(key) do
   key_s = to_string(key)
   prefix = case String.starts_with?(key_s, "--") do
     true -> ""
     false -> "--"
    end
    prefix <> Regex.replace(~r/_/, key_s, "-")
  end

  defp error!(code, desc) do
    IO.puts :stderr, ~s/#{desc}/Rd
    System.halt(code)
  end

  defp convert_tlvs(opts) do
    case SMPPSend.TlvParser.convert_tlvs(opts) do
      {:ok, opts} -> opts
      {:error, message, key} ->
        error!(1, "Error parsing tlv option #{format_keys(key)}: #{message}")
    end
  end

  defp validate_unknown(opts) do
    case SMPPSend.OptionHelpers.find_unknown(opts, [:tlvs | @switches |> Keyword.keys]) do
      [] -> opts
      unknown -> error!(1, "Unrecognized options: #{format_keys(unknown)}")
    end
  end

  defp set_defaults(opts) do
    SMPPSend.OptionHelpers.set_defaults(opts, @defaults)
  end

  defp validate_missing(opts) do
    case SMPPSend.OptionHelpers.find_missing(opts, @required) do
      [] -> opts
      missing -> error!(1, "Missing options: #{format_keys(missing)}")
    end
  end

  defp show_help(opts) do
    if opts[:help] do
      IO.puts(SMPPSend.Usage.help)
      System.halt(0)
    end
    opts
  end

  defp convert_to_ucs2(opts) do
    case SMPPSend.OptionHelpers.convert_to_ucs2(opts, :short_message) do
      {:ok, new_opts} ->
        tlvs = opts[:tlvs]
        {:ok, message_payload_id} = SMPPEX.Protocol.TlvFormat.id_by_name(:message_payload)
        case SMPPSend.OptionHelpers.convert_to_ucs2(tlvs, message_payload_id) do
          {:ok, new_tlvs} -> Keyword.put(new_opts, :tlvs, new_tlvs)
          {:error, error} -> error!(7, "Failed to convert message_payload to ucs2: #{error}")
        end
      {:error, error} -> error!(7, "Failed to convert short_message to ucs2: #{error}")
    end
  end

  defp start_servers(opts) do
    Application.start(:ranch, :permanent)
    Process.flag(:trap_exit, true)
    opts
  end

  defp bind(opts) do
    host = opts[:host]
    port = opts[:port]

    case SMPPSend.PduHelpers.bind(opts) do
      {:ok, bind} ->
        case SMPPSend.ESMEHelpers.connect(host, port, bind) do
          {:ok, esme} -> {esme, opts}
          {:error, error} -> error!(3, "Connecting SMSC failed: #{inspect error}")
        end
      {:error, error} -> error!(3, error)
    end
  end

  defp send_messages({esme, opts}) do
    message_ids = if opts[:submit_sm] do
      if opts[:udh] && opts[:split_max_bytes] do
        error!(4, "Options --udh and --split-max-bytes can't be used together")
      end

      submit_sms = cond do
        opts[:udh] -> SMPPSend.PduHelpers.submit_sms(opts, :custom_udh)
        opts[:split_max_bytes] -> SMPPSend.PduHelpers.submit_sms(opts, :auto_split)
        true -> SMPPSend.PduHelpers.submit_sms(opts, :none)
      end

      case submit_sms do
        {:ok, pdus} ->
          case SMPPSend.ESMEHelpers.send_messages(esme, pdus) do
            {:ok, message_ids} -> message_ids
            {:error, error} -> error!(6, "Message submit failed, #{error}")
          end
        {:error, error} -> error!(4, error)
      end
    else
      []
    end
    {esme, opts, message_ids}
  end

  defp wait_dlrs({esme, opts, message_ids}) do
    if opts[:wait_dlrs] do
      case SMPPSend.ESMEHelpers.wait_dlrs(esme, message_ids, opts[:wait_dlrs]) do
        :ok -> Logger.info("Dlrs for all sent messages received")
        {:error, error} -> error!(4, "Waiting dlrs failed: #{error}")
      end
    end
    {esme, opts}
  end

  defp wait({esme, opts}) do
    if opts[:wait] do
      SMPPSend.ESMEHelpers.wait_infinitely(esme)
    end
  end

end
