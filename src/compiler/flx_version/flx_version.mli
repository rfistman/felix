type version_data_t =
{
  version_string : string;
  build_time_float : float;
  build_time : string;
  buildno : int;
}

val version_data: version_data_t ref

