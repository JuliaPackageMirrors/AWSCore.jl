#==============================================================================#
# AWSCore.jl
#
# Copyright Sam O'Connor 2014 - All rights reserved
#==============================================================================#


__precompile__()


module AWSCore


export AWSException, AWSConfig, aws_config, AWSRequest, post_request, do_request


using Retry
using SymDict
using XMLDict


using Compat
import Compat: String



typealias AWSConfig SymbolDict
typealias AWSRequest SymbolDict


include("http.jl")
include("AWSException.jl")
include("AWSCredentials.jl")
include("names.jl")
include("mime.jl")



#------------------------------------------------------------------------------#
# Configuration.
#------------------------------------------------------------------------------#


function aws_config(;creds=AWSCredentials(),
                     region=get(ENV, "AWS_DEFAULT_REGION", "us-east-1"),
                     args...)
    @SymDict(creds, region, args...)
end



#------------------------------------------------------------------------------#
# AWSRequest to Request.jl conversion.
#------------------------------------------------------------------------------#


# Construct a HTTP POST request dictionary for "servce" and "query"...
#
# e.g.
# aws = Dict(:creds  => AWSCredentials(),
#            :region => "ap-southeast-2")
#
# post_request(aws, "sdb", "2009-04-15", StrDict("Action" => "ListDomains"))
#
# Dict{Symbol, Any}(
#     :creds    => creds::AWSCredentials
#     :verb     => "POST"
#     :url      => "http://sdb.ap-southeast-2.amazonaws.com/"
#     :headers  => Dict("Content-Type" =>
#                       "application/x-www-form-urlencoded; charset=utf-8)
#     :content  => "Version=2009-04-15&ContentType=JSON&Action=ListDomains"
#     :resource => "/"
#     :region   => "ap-southeast-2"
#     :service  => "sdb"
# )

function post_request(aws::AWSConfig,
                      service::String,
                      version::String,
                      query::Dict)

    resource = get(aws, :resource, "/")
    url = aws_endpoint(service, aws[:region]) * resource
    if version != ""
        query["Version"] = version
    end
    headers = Dict("Content-Type" =>
                   "application/x-www-form-urlencoded; charset=utf-8")
    content = format_query_str(query)

    @SymDict(verb = "POST", service, resource, url, headers, query, content,
             aws...)
end


# Convert AWSRequest dictionary into Requests.Request (Requests.jl)

function Request(r::AWSRequest)
    Request(r[:verb], r[:resource], r[:headers], r[:content], URI(r[:url]))
end


# Call http_request for AWSRequest.

function http_request(request::AWSRequest, args...)
    http_request(Request(request), get(request, :return_stream, false))
end


# Pretty-print AWSRequest dictionary.

function dump_aws_request(r::AWSRequest)

    action = r[:verb]
    name = r[:resource]
    if haskey(r, :query) && haskey(r[:query], "Action")
        action = r[:query]["Action"]
    end
    if haskey(r, :query)
        for k in keys(r[:query])
            if ismatch(r"[^.]Name$", k)
                name *= " "
                name *= r[:query][k]
            end
        end
    end
    println("$(r[:service]).$action $name")
end



#------------------------------------------------------------------------------#
# AWSRequest retry loop
#------------------------------------------------------------------------------#


include("sign.jl")


function do_request(r::AWSRequest)

    response = nothing

    # Try request 3 times to deal with possible Redirect and ExiredToken...
    @repeat 3 try

        # Default headers...
        if !haskey(r, :headers)
            r[:headers] = Dict()
        end
        r[:headers]["User-Agent"] = "JuliaAWS.jl/0.0.0"
        r[:headers]["Host"]       = URI(r[:url]).host

        # Load local system credentials if needed...
        if !haskey(r, :creds) || r[:creds].token == "ExpiredToken"
            r[:creds] = AWSCredentials()
        end

        # Use credentials to sign request...
        sign!(r)

        if debug_level > 0
            dump_aws_request(r)
        end

        # Send the request...
        response = http_request(r)

    catch e

        # Handle HTTP Redirect...
        @retry if http_status(e) in [301, 302, 307] &&
                  haskey(headers(e), "Location")
            r[:url] = headers(e)["Location"]
        end

        e = AWSException(e)

        if debug_level > 0
            println("Warning: AWSCore.do_request() exception: $(typeof(e))")
        end

        # Handle expired signature...
        @retry if ismatch(r"Signature expired", e.message) end

        # Handle ExpiredToken...
        @retry if typeof(e) == ExpiredToken
            r[:creds].token = "ExpiredToken"
        end
    end

    # If there is no reponse data, return raw response object...
    if typeof(response) != Response || length(response.data) < 1
        return response
    end

    # Return raw data if there is no mimetype...
    if isnull(mimetype(response))
        return response.data
    end

    # Parse response data according to mimetype...
    mime = get(mimetype(response))

    if ismatch(r"/xml$", mime)
        return parse_xml(String(response.data))
    end

    if ismatch(r"/x-amz-json-1.0$", mime)
        return JSON.parse(String(response.data))
    end

    if ismatch(r"json$", mime)
        info = JSON.parse(String(response.data))
        @protected try
            action = r[:query]["Action"]
            info = info[action * "Response"]
            info = info[action * "Result"]
        catch e
            @ignore if typeof(e) == KeyError end
        end
        return info
    end

    if ismatch(r"^text/", mime)
        return String(response.data)
    end

    # Return raw data by default...
    return response.data
end


global debug_level = 0

function set_debug_level(n)
    global debug_level = n
end



end # module AWSCore


#==============================================================================#
# End of file.
#==============================================================================#
