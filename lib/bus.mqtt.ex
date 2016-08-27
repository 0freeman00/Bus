defmodule Bus.Mqtt do
	 import GenServer
	 require Logger 

	 alias Bus.Message
	 alias Bus.Protocol.Packet
	 alias Bus.IdProvider

   #if possible, add Id provider map here only in this state.
   #then it will be so independent of other process.
   @initial_state %{
        socket: nil, #to send & receive data
        timeout: 0,  #mqtt keep_alive timeout
        auto_reconnect: false #reconnect auto,if disconnect.
   }

	  def start_link do
	    GenServer.start_link(__MODULE__,@initial_state,[name: __MODULE__])
	  end


    # connect to mqtt,
    # take params from config.
    def init(state) do
      if Application.get_env(:bus,:auto_connect, true) do
          case connect(:auto) do
               {:ok,socket,timeout,auto_reconnect} ->
                   IO.inspect "Auto connected."
                   {:ok,%{socket: socket,timeout: timeout, auto_reconnect: auto_reconnect}}
                _ ->
                   {:ok,state}
          end
      else
          {:ok,state}
      end
    end


    #store whole these details in state.
    #create arguments , to get info from.
    #argument can be struct. 
    def connect() do
        GenServer.call(__MODULE__, {:connect})
    end

    #auto connect.
    def connect(:auto) do
                 host = Application.get_env(:bus, :host, 'localhost')
                 port = Application.get_env(:bus, :port, 1883)
                 client_id = Application.get_env(:bus, :client_id, 1)
                 username = Application.get_env(:bus, :username, "")
                 password = Application.get_env(:bus, :password, "")
                 will_topic = ""
                 will_message = ""
                 will_qos = 1
                 will_retain = 0
                 clean_session = 1
                 keep_alive = Application.get_env(:bus, :keep_alive, 120) #sec
                 auto_reconnect = Application.get_env(:bus, :auto_reconnect, false)

                 message = Packet.encode(Message.connect(client_id, username, password,
                                  will_topic, will_message, will_qos,
                                  will_retain, clean_session, keep_alive))

                 timeout = get_timeout(keep_alive)

                 tcp_opts = [:binary, active: :once]
                 tcp_time_out = 10_000 #milliseconds

                 case :gen_tcp.connect(host, port, tcp_opts,tcp_time_out) do
                    {:ok, socket}    ->
                        :gen_tcp.send(socket,message)
                        {:ok, socket,timeout,auto_reconnect}
                    {:error, :econnrefused} ->
                        IO.inspect "Could not reach to server."
                        {:error,"could not reach to server."}
                    {:error, Reason} ->
                        IO.inspect "Error while connecting."
                        IO.inspect Reason
                        {:error,Reason}
                  end
    end

    def handle_call({:connect,opts},_From,state) do
        case connect(:auto) do
               {:ok,socket,timeout,auto_reconnect} ->
                   IO.inspect "Connected."
                   {:ok,%{socket: socket,timeout: timeout, auto_reconnect: auto_reconnect}}
                _ ->
                   {:ok,state}
          end
    end


	  def disconnect() do
	  	GenServer.cast( __MODULE__ , :disconnect)
	  end

	  def publish(topic,message,qos,dup,retain) do
	  	opts = %{
	  		topic: topic,
	  		message: message,
	  		dup: dup,
	  		qos: qos,
	  		retain: retain
	  	}
	  	GenServer.cast( __MODULE__ , { :publish , opts })
	  end

	  # list_of_data = [{topic,qos},{topic,qos}]
	  def subscribe() do
	  	GenServer.cast( __MODULE__ , { :subscribe , ["a","b"],[1,1]})
	  end

    #check if arg is list or not.
	  def unsubscribe(list_of_topics) do
	  	GenServer.cast( __MODULE__ , { :unsubscribe , list_of_topics})
	  end

	  def pingreq do
	  	GenServer.cast( __MODULE__ , :ping)
	  end


  	 #define How to get ID. may be we need one process to manage ids, or Agent.
  	 #think and implement.
  	 def handle_cast({:publish, opts},%{socket: socket, timeout: timeout} = state) do
       
        topic  = opts |> Map.fetch!(:topic) #""
        msg    = opts |> Map.fetch!(:message) #""
        dup    = opts |> Map.fetch!(:dup) #bool
        qos    = opts |> Map.fetch!(:qos) #int
        retain = opts |> Map.fetch!(:retain) #bool

        message =
          case qos do
            0 ->
              Message.publish(topic, msg, dup, qos, retain)
            _ ->
              id = IdProvider.get_id
              Message.publish(id, topic, msg, dup, qos, retain)
          end

        :gen_tcp.send(socket,Packet.encode(message))
        {:noreply, state,timeout}

      end

      def handle_cast({:subscribe,topics,qoses}, %{socket: socket, timeout: timeout} = state) do   
        id     = IdProvider.get_id
        message = Message.subscribe(id, topics, qoses)
    	  :gen_tcp.send(socket,Packet.encode(message))
        {:noreply, state ,timeout}
      end

      #get id from agent.
      def handle_cast({:unsubscribe, topics}, %{socket: socket,timeout: timeout} = state) do
        id      = IdProvider.get_id
        message = Message.unsubscribe(id, topics)
        :gen_tcp.send(socket,Packet.encode(message))
        {:noreply, state,timeout}
      end

      def handle_cast(:ping, %{socket: socket, timeout: timeout} = state) do
        message = Message.ping_request
        :gen_tcp.send(socket,Packet.encode(message))
        {:noreply,state,timeout}
      end

      def handle_cast(:disconnect, %{socket: socket, timeout: timeout} = state) do
        message = Message.disconnect
        :gen_tcp.send(socket,Packet.encode(message))
        {:noreply, state,timeout}
      end

  	 #all the messages will from tcp will be received here.
  	 #this will be the entry point of all the tcp messages,
  	 #get message from here, decode it and process it.
  	 def handle_info({:tcp, socket, msg}, %{socket: socket,timeout: timeout} = state) do
      %{message: message,remainder: remainder} = Packet.decode msg
  	 	case message do
         %Bus.Message.ConnAck{} ->
            Bus.Callback.on_connect({:ok,"connection successful"})
         %Bus.Message.PubAck{} -> #this will only call when QoS = 1
            Bus.Callback.on_publish({:ok,1,"publish successful"})
         %Bus.Message.PubRec{id: id} -> #this will only call when QoS = 2
            pub_rel_msg = Message.publish_release(id)
            :gen_tcp.send(socket,Packet.encode(pub_rel_msg))
         %Bus.Message.PubComp{} -> #this will only call when QoS = 2
            Bus.Callback.on_publish({:ok,2,"publish successful"})
         %Bus.Message.SubAck{} ->
            Bus.Callback.on_subscribe({:ok,"subscribe successful"})
         %Bus.Message.PingResp{} -> #this is internal use.increase the timeout.
            IO.inspect "Ping resp came."
         %Bus.Message.UnsubAck{} ->
            Bus.Callback.on_unsubscribe({:ok,"unsubscribe successful"})
         _ ->
            Logger.debug "Error while receiving packet."
      end
  	 	:inet.setopts(socket, active: :once)
  	 	{:noreply, state,timeout}
  	 end

     def handle_info(:timeout,%{socket: socket,timeout: timeout} = state) do
         IO.inspect "Timeout occurs."
         message = Message.ping_request
         :gen_tcp.send(socket,Packet.encode(message))
         {:noreply,state,timeout}
     end

  	 #This will call when tcp will be closed, try to reconnect.
  	 def handle_info({:tcp_closed, socket}, %{socket: socket,timeout: timeout,auto_reconnect: auto_reconnect} = state) do
      if auto_reconnect == true do
        reconnect()
       end
  	 end

  	 def terminate(reason,state) do
  	 	:ok
  	 end

  	 def code_change(_old_ver,state,_extra) do
  	 	{:ok, state}
  	 end
     
     #if client id is int , it will convert to string.
     defp get_client_id(id) do
      case is_number(id) do
            true -> to_string(id) 
            _    -> id
      end 
     end

     defp reconnect() do
         IO.inspect "Reconnection in process."
        case connect(:auto) do
               {:ok,socket,timeout,auto_reconnect} ->
                   IO.inspect "Auto Reconnection successful."
                   {:noreply,%{socket: socket,timeout: timeout, auto_reconnect: auto_reconnect}}
                _ ->
                   :timer.sleep(2000)
                   reconnect()
          end
     end
     defp get_timeout(keep_alive) do
            if keep_alive == 0 do
                :infinity
            else
                (keep_alive*1000) - 5; # we will send pingreq before 5 sec of timeout.
            end
     end
end