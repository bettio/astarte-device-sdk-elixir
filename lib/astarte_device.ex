#
# This file is part of Astarte.
#
# Copyright 2019 Ispirata Srl
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#    http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.
#

defmodule Astarte.Device do
  @moduledoc """
  A process that manages a device connection to Astarte. See `Astarte.Device.start_link/1` for the options.
  """

  @behaviour :gen_statem

  require Logger

  # 7 days
  @nearly_expired_seconds 7 * 24 * 60 * 60
  @key_size 4096

  defmodule Data do
    @moduledoc false

    defstruct [
      :pairing_url,
      :realm,
      :device_id,
      :client_id,
      :credentials_secret,
      :broker_url,
      :credential_storage_mod,
      :credential_storage_state
    ]
  end

  # API

  @doc """
  Start an `Astarte.Device`.

  ## Device Options
    * `pairing_url` - URL of the Astarte Pairing API instance the device will connect to, up to (and including) `/v1`. E.g. `https://astarte.api.example.com/pairing/v1` or `http://localhost:4003/v1` for a local installation.
    * `realm` - Realm which the device belongs to.
    * `device_id` - Device ID of the device. The device ID must be 128-bit long and must be encoded with url-safe base64 without padding. You can generate a random one with `:crypto.strong_rand_bytes(16) |> Base.url_encode64(padding: false)`.
    * `credentials_secret` - The credentials secret obtained when registering the device using Pairing API (to register a device use `Astarte.API.Pairing.Agent.register_device/2` or see https://docs.astarte-platform.org/latest/api/index.html?urls.primaryName=Pairing%20API#/agent/registerDevice).
    * `credential_storage` - A tuple `{module, args}` where `module` is a module implementing `Astarte.Device.CredentialStorage` behaviour and `args` are the arguments passed to its init function
  """
  @spec start_link(device_options) :: :gen_statem.start_ret()
        when device_option:
               {:pairing_url, String.t()}
               | {:realm, String.t()}
               | {:device_id, String.t()}
               | {:credentials_secret, String.t()}
               | {:credential_storage, {module(), term()}},
             device_options: [device_option]
  def start_link(device_options) do
    pairing_url = Keyword.fetch!(device_options, :pairing_url)
    realm = Keyword.fetch!(device_options, :realm)
    device_id = Keyword.fetch!(device_options, :device_id)
    client_id = "#{realm}/#{device_id}"
    credentials_secret = Keyword.fetch!(device_options, :credentials_secret)

    {credential_storage_mod, credential_storage_args} =
      Keyword.fetch!(device_options, :credential_storage)

    case apply(credential_storage_mod, :init, [credential_storage_args]) do
      {:ok, credential_storage_state} ->
        data = %Data{
          pairing_url: pairing_url,
          realm: realm,
          device_id: device_id,
          client_id: client_id,
          credentials_secret: credentials_secret,
          credential_storage_mod: credential_storage_mod,
          credential_storage_state: credential_storage_state
        }

        :gen_statem.start_link(__MODULE__, data, [])

      {:error, reason} ->
        Logger.warn(
          "#{client_id}: Can't initialize CredentialStorage for #{client_id}: #{inspect(reason)}"
        )

        {:error, :credential_storage_failed}
    end
  end

  # Callbacks

  def callback_mode, do: :state_functions

  def init(data) do
    %Data{
      credential_storage_mod: credential_storage_mod,
      credential_storage_state: credential_storage_state
    } = data

    with {:keypair, true} <-
           {:keypair, apply(credential_storage_mod, :has_keypair?, [credential_storage_state])},
         {:certificate, {:ok, pem_certificate}} <-
           {:certificate,
            apply(credential_storage_mod, :fetch, [:certificate, credential_storage_state])},
         {:valid_certificate, true} <-
           {:valid_certificate, valid_certificate?(pem_certificate)} do
      actions = [{:next_event, :internal, :connect}]
      {:ok, :disconnected, data, actions}
    else
      {:keypair, false} ->
        actions = [{:next_event, :internal, :generate_keypair}]
        {:ok, :no_keypair, data, actions}

      {:certificate, :error} ->
        {:ok, :no_certificate, data}

      {:valid_certificate, false} ->
        # If the certificate is invalid, we treat it like it's not there
        {:ok, :no_certificate, data}

      {:error, reason} ->
        {:stop, reason}
    end
  end

  defp valid_certificate?(pem_certificate) do
    with {:ok, certificate} <- X509.Certificate.from_pem(pem_certificate) do
      {:Validity, _not_before, not_after} = X509.Certificate.validity(certificate)

      seconds_until_expiry =
        not_after
        |> X509.DateTime.to_datetime()
        |> DateTime.diff(DateTime.utc_now())

      # If the certificate it's near its expiration, we treat it as invalid
      seconds_until_expiry > @nearly_expired_seconds
    else
      {:error, _reason} ->
        false
    end
  end

  def no_keypair(:internal, :generate_keypair, data) do
    %Data{
      client_id: client_id,
      credential_storage_mod: credential_storage_mod,
      credential_storage_state: credential_storage_state
    } = data

    Logger.info("#{client_id}: Generating a new keypair")

    # TODO: make crypto configurable (RSA/EC, key size/curve)
    private_key = X509.PrivateKey.new_rsa(@key_size)

    pem_csr =
      private_key
      |> X509.CSR.new("CN=#{client_id}")
      |> X509.CSR.to_pem()

    pem_private_key = X509.PrivateKey.to_pem(private_key)

    with {:ok, with_key_state} <-
           apply(credential_storage_mod, :save, [
             :private_key,
             pem_private_key,
             credential_storage_state
           ]),
         {:ok, with_key_and_csr_state} <-
           apply(credential_storage_mod, :save, [:csr, pem_csr, with_key_state]) do
      new_data = %{data | credential_storage_state: with_key_and_csr_state}
      actions = [{:next_event, :internal, :request_certificate}]

      {:next_state, :no_certificate, new_data, actions}
    else
      {:error, reason} ->
        # TODO: exponential backoff
        Logger.warn(
          "#{client_id}: Failed to save keypair to credential storage: #{inspect(reason)}, trying again in 5 seconds"
        )

        actions = [{:state_timeout, 5000, :retry_generate_keypair}]
        {:keep_state_and_data, actions}
    end
  end

  def no_keypair(:state_timeout, :retry_generate_keypair, _data) do
    actions = [{:next_event, :internal, :generate_keypair}]
    {:keep_state_and_data, actions}
  end

  def no_certificate(:internal, :request_certificate, data) do
    %Data{
      client_id: client_id,
      pairing_url: pairing_url,
      realm: realm,
      credentials_secret: credentials_secret,
      device_id: device_id,
      credential_storage_mod: credential_storage_mod,
      credential_storage_state: credential_storage_state
    } = data

    Logger.info("#{client_id}: Requesting new certificate")

    client = Astarte.API.Pairing.client(pairing_url, realm, auth_token: credentials_secret)
    {:ok, csr} = apply(credential_storage_mod, :fetch, [:csr, credential_storage_state])

    with {:api, {:ok, %{status: 201, body: body}}} <-
           {:api, Astarte.API.Pairing.Devices.get_mqtt_v1_credentials(client, device_id, csr)},
         %{"data" => %{"client_crt" => pem_certificate}} = body,
         {:store, {:ok, new_credential_storage_state}} <-
           {:store,
            apply(credential_storage_mod, :save, [
              :certificate,
              pem_certificate,
              credential_storage_state
            ])} do
      Logger.info("#{client_id}: Received new certificate")
      new_data = %{data | credential_storage_state: new_credential_storage_state}
      actions = [{:next_event, :internal, :request_info}]
      {:next_state, :waiting_for_info, new_data, actions}
    else
      {:api, {:error, reason}} ->
        # HTTP request can't be made
        # TODO: exponential backoff
        Logger.warn(
          "#{client_id}: Failed to ask for a certificate: #{inspect(reason)}. Trying again in 30 seconds"
        )

        actions = [{:state_timeout, 30_000, :retry_request_certificate}]
        {:keep_state_and_data, actions}

      {:api, {:ok, %{status: status, body: body}}} ->
        # HTTP request succeeded but returned an error status
        # TODO: pattern match on the status + exponential backoff
        Logger.warn(
          "#{client_id}: Get credentials failed with status #{status}: #{inspect(body)}. Trying again in 30 seconds."
        )

        actions = [{:state_timeout, 30_000, :retry_request_certificate}]
        {:keep_state_and_data, actions}

      {:store, {:error, reason}} ->
        # TODO: exponential backoff
        Logger.warn(
          "#{client_id}: Credential storage could not save certificate: #{inspect(reason)}. Trying again in 30 seconds."
        )

        actions = [{:state_timeout, 30_000, :retry_request_certificate}]
        {:keep_state_and_data, actions}
    end
  end

  def no_certificate(:state_timeout, :retry_request_certificate, _data) do
    actions = [{:next_event, :internal, :request_certificate}]
    {:keep_state_and_data, actions}
  end

  def waiting_for_info(:internal, :request_info, data) do
    %Data{
      client_id: client_id,
      credentials_secret: credentials_secret,
      pairing_url: pairing_url,
      realm: realm,
      device_id: device_id
    } = data

    Logger.info("#{client_id}: Requesting info")

    client = Astarte.API.Pairing.client(pairing_url, realm, auth_token: credentials_secret)

    with {:ok, %{status: 200, body: body}} <- Astarte.API.Pairing.Devices.info(client, device_id),
         broker_url when not is_nil(broker_url) <-
           get_in(body, ["data", "protocols", "astarte_mqtt_v1", "broker_url"]) do
      Logger.info("#{client_id}: Broker url is #{broker_url}")
      new_data = %{data | broker_url: broker_url}
      actions = [{:next_event, :internal, :connect}]
      {:next_state, :disconnected, new_data, actions}
    else
      {:error, reason} ->
        # HTTP request can't be made
        # TODO: exponential backoff
        Logger.warn(
          "#{client_id}: Failed to obtain transport info: #{inspect(reason)}. Trying again in 30 seconds"
        )

        actions = [{:state_timeout, 30_000, :retry_request_info}]
        {:keep_state_and_data, actions}

      {:ok, %{status: status, body: body}} ->
        # HTTP request succeeded but returned an error status
        # TODO: pattern match on the status + exponential backoff
        Logger.warn(
          "#{client_id}: Get info failed with status #{status}: #{inspect(body)}. Trying again in 30 seconds."
        )

        actions = [{:state_timeout, 30_000, :retry_request_info}]
        {:keep_state_and_data, actions}
    end
  end

  def waiting_for_info(:state_timeout, :retry_request_info, _data) do
    actions = [{:next_event, :internal, :request_info}]
    {:keep_state_and_data, actions}
  end

  def disconnected(_event_type, _event, _data) do
    :keep_state_and_data
  end
end
