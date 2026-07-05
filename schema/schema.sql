-- Music Room App Supabase Schema

-- Create the songs table to track all uploaded audio files globally.
CREATE TABLE public.songs (
    id UUID DEFAULT gen_random_uuid() PRIMARY KEY,
    title TEXT NOT NULL,
    url TEXT NOT NULL,
    created_at TIMESTAMP WITH TIME ZONE DEFAULT timezone('utc'::text, now()) NOT NULL
);

-- Create the rooms table to track current playback state for sync.
CREATE TABLE public.rooms (
    id TEXT PRIMARY KEY,
    name TEXT NOT NULL,
    current_song_id UUID REFERENCES public.songs(id),
    position_ms BIGINT DEFAULT 0,
    is_playing BOOLEAN DEFAULT false,
    updated_at TIMESTAMP WITH TIME ZONE DEFAULT timezone('utc'::text, now()) NOT NULL,
    created_at TIMESTAMP WITH TIME ZONE DEFAULT timezone('utc'::text, now()) NOT NULL
);

-- Enable Row Level Security (RLS) and allow public access for simplicity.
ALTER TABLE public.songs ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.rooms ENABLE ROW LEVEL SECURITY;

-- Allow anonymous read and insert for the prototype.
CREATE POLICY "Allow public read access on songs" ON public.songs FOR SELECT USING (true);
CREATE POLICY "Allow public insert on songs" ON public.songs FOR INSERT WITH CHECK (true);
CREATE POLICY "Allow public delete on songs" ON public.songs FOR DELETE USING (true);

CREATE POLICY "Allow public read access on rooms" ON public.rooms FOR SELECT USING (true);
CREATE POLICY "Allow public insert on rooms" ON public.rooms FOR INSERT WITH CHECK (true);
CREATE POLICY "Allow public update on rooms" ON public.rooms FOR UPDATE USING (true);

-- Create a bucket for storing audio files (if it doesn't exist).
-- NOTE: In the Supabase dashboard, you must ensure the 'songs' bucket exists and is public.
INSERT INTO storage.buckets (id, name, public) 
VALUES ('songs', 'songs', true) 
ON CONFLICT (id) DO NOTHING;

-- Storage policies for the 'songs' bucket
CREATE POLICY "Public Access" 
ON storage.objects FOR SELECT 
USING ( bucket_id = 'songs' );

CREATE POLICY "Public Upload" 
ON storage.objects FOR INSERT 
WITH CHECK ( bucket_id = 'songs' );

CREATE POLICY "Public Delete" 
ON storage.objects FOR DELETE 
USING ( bucket_id = 'songs' );

-- Enable realtime for the rooms table to listen for playback changes.
alter publication supabase_realtime add table public.rooms;
